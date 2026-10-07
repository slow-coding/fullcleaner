// 自检：在临时样本目录里搭一套"假系统"（假应用、假残留、假 /Library），
// 把匹配规则、置信度、默认勾选、闸门、执行、复核全跑一遍，然后核对结果。
// 全程不碰真实的用户目录：所有路径都从 FULLCLEANER_HOME / FULLCLEANER_SYSTEM_ROOT 推出来。
// 用法：fullcleaner --selftest

import Foundation

enum SelfTest {

    private static var passed = 0
    private static var failed = 0
    private static var root = ""

    private static func check(_ ok: Bool, _ message: String) {
        if ok { passed += 1; print("  ✓ \(message)") } else { failed += 1; print("  ✗ \(message)") }
    }

    private static func section(_ title: String) { print("\n\(title)") }

    static func run() -> Bool {
        root = NSTemporaryDirectory() + "fullcleaner-selftest-\(UUID().uuidString.prefix(6))"
        buildSample()
        setEnvironment()

        print("FullCleaner 自检 · 样本目录 \(root)")
        checkScanners()
        checkPermissions()
        checkSorting()
        checkScope()
        checkGates()
        let removed = checkRemoval()
        checkNoStrayDeletion(removed)

        print("\n结果：\(passed) 通过 · \(failed) 失败")
        if failed == 0 {
            try? FileManager.default.removeItem(atPath: root)
        } else {
            print("样本目录留在 \(root)，可以自己看一眼")
        }
        return failed == 0
    }

    // MARK: - 搭样本

    private static func write(_ path: String, _ text: String) {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func plist(_ path: String, _ values: [String: Any]) {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        (values as NSDictionary).write(toFile: path, atomically: true)
    }

    private static var home: String { root + "/home" }
    private static var appsDirectory: String { root + "/apps" }
    private static var systemRoot: String { root + "/system" }

    private static func buildSample() {
        // 两个假应用
        plist(appsDirectory + "/Fake App.app/Contents/Info.plist", [
            "CFBundleIdentifier": "com.example.fake",
            "CFBundleName": "Fake App",
            "CFBundleDisplayName": "Fake App",
            "CFBundleExecutable": "FakeApp",
            "CFBundleShortVersionString": "3.2.1",
        ])
        write(appsDirectory + "/Fake App.app/Contents/MacOS/FakeApp", "#!/bin/sh\n")
        plist(appsDirectory + "/Fake App.app/Contents/Library/LoginItems/FakeHelper.app/Contents/Info.plist", [
            "CFBundleIdentifier": "com.example.fake.helper",
            "CFBundleName": "FakeHelper",
        ])
        plist(appsDirectory + "/Fake App.app/Contents/Library/LaunchAgents/com.example.fake.agent.plist", [
            "Label": "com.example.fake.agent",
            "ProgramArguments": [appsDirectory + "/Fake App.app/Contents/MacOS/FakeApp"],
        ])
        plist(appsDirectory + "/Unverified.app/Contents/Info.plist", [
            "CFBundleIdentifier": "com.example.unverified",
            "CFBundleName": "Unverified",
            "CFBundleDisplayName": "Unverified",
        ])

        // 残留
        write(home + "/Library/Containers/com.example.fake/Data/notes.txt", "hello")
        write(home + "/Library/Containers/com.example.fake.helper/Data/log.txt", "hello")
        write(home + "/Library/Containers/com.example.other/Data/keep.txt", "别删我")
        write(home + "/Library/Group Containers/group.com.example.fake/shared.txt", "shared")
        write(home + "/Library/Preferences/com.example.fake.plist", "<plist/>")
        write(home + "/Library/Preferences/com.apple.fake.plist", "<plist/>")
        write(home + "/Library/Caches/com.example.fake/cache.bin", "cache")
        write(home + "/Library/Application Support/Fake App/notes.json", "{\"bundle\":\"com.example.fake\"}")
        write(home + "/Library/Application Support/Unverified/something.txt", "没有提到那个应用")
        write(home + "/Library/LaunchAgents/com.example.fake.agent.plist",
              "<plist><string>\(appsDirectory)/Fake App.app</string></plist>")
        write(home + "/Library/Mobile Documents/iCloud~com~example~fake/Documents/x.txt", "icloud")
        write(systemRoot + "/Library/Application Support/com.example.fake/data.bin", "system level")
        // 名字里有单引号与空格：删除走批处理脚本，转义错了就会删错东西
        write(systemRoot + "/Library/Application Support/it's a \"test\"/inner/data.bin", "quote test")
        write(root + "/decoy-keep.txt", "不该被动")
        // 闸门用的样本
        write(home + "/Documents/paper.txt", "用户文稿")
        write(home + "/Library/Caches/target-dir/inside.txt", "子目录")
        try? FileManager.default.createSymbolicLink(atPath: home + "/Library/Caches/decoy-link", withDestinationPath: home + "/Library/Containers")
    }

    private static func setEnvironment() {
        setenv("FULLCLEANER_HOME", home, 1)
        setenv("FULLCLEANER_SYSTEM_ROOT", systemRoot, 1)
        setenv("FULLCLEANER_APP_DIRS", appsDirectory, 1)
        setenv("FULLCLEANER_NO_ADMIN", "1", 1)
        setenv("FULLCLEANER_NO_TCC", "1", 1)
        setenv("FULLCLEANER_SELFTEST", "1", 1)
        setenv("FULLCLEANER_PKG_LIST", "com.example.fake.pkg\ncom.other.pkg", 1)
        setenv("FULLCLEANER_FAKE_FDA", "1", 1)     // 默认按"已授权"跑；未授权分支在 checkScope 里单独验
        Remover.trashHandler = { url in
            let trash = URL(fileURLWithPath: Paths.trash)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    // MARK: - 扫描与匹配

    private static func checkScanners() {
        section("扫描")
        let apps = AppScanner.scan()
        check(apps.count == 2, "扫到 2 个应用（实际 \(apps.count)）")
        guard let fake = apps.first(where: { $0.bundleID == "com.example.fake" }) else {
            check(false, "找到 Fake App"); return
        }
        check(fake.name == "Fake App", "名字读对：\(fake.name)")
        check(fake.version == "3.2.1", "版本读对：\(fake.version)")
        check(fake.nestedBundleIDs == ["com.example.fake.helper"], "包内子程序 id 读出来：\(fake.nestedBundleIDs)")
        check(fake.loginItemLabels == ["com.example.fake.agent"], "包内自启项 label 读出来：\(fake.loginItemLabels)")
        check(!fake.protected, "第三方应用不算受保护应用")

        section("残留匹配")
        let hits = ResidueScanner.residues(for: fake, measure: true)
        let paths = hits.map { $0.path }
        func hit(_ path: String) -> ResidueScanner.Hit? { hits.first { $0.path == Paths.home + path } }

        check(hit("/Library/Containers/com.example.fake")?.how == .exactID, "容器按 bundle id 精确命中")
        check(hit("/Library/Containers/com.example.fake.helper")?.how == .idPrefix, "帮助程序容器按前缀命中")
        check(!paths.contains(Paths.home + "/Library/Containers/com.example.other"), "别的应用的容器没被牵连")
        check(hit("/Library/Preferences/com.example.fake.plist")?.kind == .preferences, "偏好 plist 命中")
        check(hit("/Library/Group Containers/group.com.example.fake")?.how == .appGroup, "共享容器按 App Group 命中")
        check(hit("/Library/Caches/com.example.fake")?.kind == .cache, "缓存命中")
        check(hit("/Library/Application Support/Fake App")?.how == .appName, "应用支持目录按名字命中")
        let agent = hit("/Library/LaunchAgents/com.example.fake.agent.plist")
        check(agent?.kind == .launchAgent && (agent?.how == .loginItem || agent?.how == .idPrefix), "自启项命中（按 label 或 bundle id 前缀）")
        check(hit("/Library/Mobile Documents/iCloud~com~example~fake")?.kind == .iCloudContainer, "iCloud 容器命中")
        if let systemHit = hits.first(where: { $0.kind == .systemLibrary }) {
            check(true, "系统级残留命中：\(Format.short(systemHit.path))")
        } else {
            check(false, "系统级残留（/Library/Application Support 下）应命中")
        }
        let receipts = hits.filter { $0.kind == .packageReceipt }
        check(receipts.count == 1 && receipts[0].path == "com.example.fake.pkg", "安装包收据只命中自己的那条")
        check(hits.allSatisfy { $0.kind == .packageReceipt || $0.path.hasPrefix(root) }, "所有命中路径都在样本目录里（没有扫到真系统）")
    }

    // MARK: - 权限

    private static func checkPermissions() {
        section("权限")
        check(Permission.allCases.count == 3, "面板三项：完全磁盘访问、文件与文件夹（由前者覆盖）、App 管理")
        check(Permissions.all().allSatisfy { !$0.permission.purpose.isEmpty }, "每项都写了用途")
        check(Permissions.all().allSatisfy { $0.permission.settingsURL.hasPrefix("x-apple.systempreferences:") },
              "每项都能一键打开系统设置里对应的那一页")
        check(Permissions.status(.fullDiskAccess) == .missing, "样本环境读不到权限数据库 → 完全磁盘访问判为未授权")
        check(Permissions.status(.filesAndFolders) == .missing, "文件与文件夹那一行跟着完全磁盘访问一起变化")
        check(Permissions.status(.appManagement) == .unknown, "完全磁盘访问没给时，App 管理标为「检测不了」而不是乱猜")
    }

    // MARK: - 排序

    private static func checkSorting() {
        section("排序")
        func app(_ name: String, bytes: Int64, daysAgo: Int?, opens: Int?) -> AppItem {
            AppItem(path: "/Applications/\(name).app", bundleID: "com.example.\(name.lowercased())", name: name,
                    version: "1", bytes: bytes, isSystem: false, isMAS: false, rootOwned: false,
                    executableName: name, nestedBundleIDs: [], loginItemLabels: [], appGroups: [],
                    iCloudContainers: [], modified: nil,
                    lastOpened: daysAgo.map { Date().addingTimeInterval(-86_400 * Double($0)) },
                    openCount: opens)
        }
        let apps = [app("Beta", bytes: 100, daysAgo: 5, opens: 900),
                    app("alpha", bytes: 300, daysAgo: nil, opens: nil),
                    app("Gamma", bytes: 200, daysAgo: 40, opens: 3)]
        check(SortKey.sorted(apps, by: .size, ascending: false).map { $0.name } == ["alpha", "Gamma", "Beta"],
              "按大小降序：大的在前")
        check(SortKey.sorted(apps, by: .size, ascending: true).map { $0.name } == ["Beta", "Gamma", "alpha"],
              "再点一次（升序）：小的在前")
        check(SortKey.sorted(apps, by: .lastOpened, ascending: false).map { $0.name } == ["Beta", "Gamma", "alpha"],
              "按上次打开时间：默认最近的在最上，没时间的排最后")
        check(SortKey.sorted(apps, by: .lastOpened, ascending: true).map { $0.name } == ["Gamma", "Beta", "alpha"],
              "翻转后：最久没打开的在前，没时间的仍在最后")
        check(SortKey.sorted(apps, by: .openCount, ascending: false).map { $0.name } == ["Beta", "Gamma", "alpha"],
              "按打开次数：次数多的在前，没次数的排最后")
        check(SortKey.sorted(apps, by: .nameAsc, ascending: true).map { $0.name } == ["alpha", "Beta", "Gamma"],
              "按名称 A→Z（不区分大小写）")
        check(SortKey.sorted(apps, by: .nameAsc, ascending: false).map { $0.name } == ["Gamma", "Beta", "alpha"],
              "名称翻转：Z→A")
    }

    // MARK: - 进清单的范围（拿不准的不进清单、不问用户）

    private static func checkScope() {
        section("进清单的范围")
        let apps = AppScanner.scan()
        guard let fake = apps.first(where: { $0.bundleID == "com.example.fake" }),
              let unverified = apps.first(where: { $0.bundleID == "com.example.unverified" }) else { return }

        let planned = Planner.build(apps: [fake, unverified], all: apps)
        func item(_ path: String, app: String = "Fake App.app") -> PlanItem? {
            planned.items.first { $0.path == Paths.home + path && $0.appPath.hasSuffix(app) }
        }
        func skipped(_ path: String) -> Skipped? {
            planned.skipped.first { $0.path == Paths.home + path }
        }

        check(planned.items.first { $0.isAppBundle && $0.appPath.hasSuffix("Fake App.app") }?.checked == true,
              "应用本体在清单里，默认勾选")
        check(item("/Library/Containers/com.example.fake")?.checked == true, "容器：在清单里，默认勾选")
        check(item("/Library/Containers/com.example.fake")?.match == .exactID, "容器：按 bundle id 匹配")
        check(item("/Library/Caches/com.example.fake") != nil, "缓存：在清单里")
        check(item("/Library/Application Support/Fake App") != nil, "按名字匹配但读到证据：进清单")
        check(item("/Library/Group Containers/group.com.example.fake") != nil, "没人共用的共享容器：进清单")
        check(item("/Library/LaunchAgents/com.example.fake.agent.plist") != nil, "自启项：在清单里")

        check(item("/Library/Application Support/Unverified") == nil, "只有名字像的：不进清单")
        check(skipped("/Library/Application Support/Unverified")?.reason.contains("没有证据") == true,
              "并在跳过清单里写明原因")
        check(item("/Library/Mobile Documents/iCloud~com~example~fake") == nil, "iCloud 数据：不进清单")
        check(skipped("/Library/Mobile Documents/iCloud~com~example~fake") != nil, "iCloud 数据记进跳过清单")

        // 共用容器：合成两个都声明同一个 App Group 的应用
        var sharedA = fake
        sharedA.appGroups = ["group.com.example.shared"]
        var sharedB = unverified
        sharedB.bundleID = "com.example.other"
        sharedB.appGroups = ["group.com.example.shared"]
        let registry = SharedRegistry(apps: [sharedA, sharedB])
        check(registry.claimants(of: "group.com.example.shared", excluding: sharedA).contains("Unverified"),
              "共用检测：认出另一个声明了同一个 App Group 的应用")
        check(SharedRegistry(apps: [sharedA]).claimants(of: "group.com.example.shared", excluding: sharedA).isEmpty,
              "应用自己声明的容器不算共用")
        var sharedItem = PlanItem(appPath: sharedA.path, appName: sharedA.name,
                                  path: Paths.home + "/Library/Group Containers/group.com.example.shared",
                                  bytes: 10, kind: .groupContainer, match: .appGroup)
        sharedItem.sharedWith = registry.claimants(of: "group.com.example.shared", excluding: sharedA)
        check(Planner.reject(sharedItem, app: sharedA)?.gate == "不误伤", "共用容器：闸门拦下")

        // 没有完全磁盘访问时的策略：不去碰会弹窗的位置
        unsetenv("FULLCLEANER_FAKE_FDA")
        let noFDA = ResidueScanner.residues(for: fake, measure: true)
        check(!noFDA.contains { $0.kind == .iCloudContainer }, "没给完全磁盘访问：iCloud Drive 整段不碰（不弹窗）")
        check(noFDA.contains { $0.kind == .container }, "容器仍然列出来（能删，只是量不了体积）")
        check(noFDA.first { $0.kind == .container }?.bytes == 0, "没给完全磁盘访问：容器体积留空，不进去走一遍")
        setenv("FULLCLEANER_FAKE_FDA", "1", 1)
        check(ResidueScanner.residues(for: fake, measure: true).contains { $0.kind == .iCloudContainer },
              "给了完全磁盘访问：iCloud 照常扫")
    }

    // MARK: - 闸门

    private static func checkGates() {
        section("闸门")
        let apps = AppScanner.scan()
        let app = apps.first { $0.bundleID == "com.example.fake" }
        func item(_ path: String, kind: ResidueKind = .cache, appPath: String? = nil) -> PlanItem {
            PlanItem(appPath: appPath ?? app?.path ?? "", appName: "Fake App", path: path, bytes: 1, kind: kind, match: .exactID)
        }
        check(Planner.reject(item(home + "/Documents/paper.txt"), app: app)?.gate == "保护名单", "用户文稿目录里的东西不动")
        check(Planner.reject(item(home), app: app)?.gate == "保护名单", "家目录本身不动")
        check(Planner.reject(item(Paths.library + "/Preferences"), app: app)?.gate == "保护名单", "受保护目录本身不动")
        check(Planner.reject(item(Paths.library + "/Preferences/com.apple.fake.plist"), app: app)?.gate == "保护名单",
              "系统自己的偏好设置不动")
        check(Planner.reject(item(home + "/Library/Caches/decoy-link"), app: app)?.gate == "路径形态", "符号链接不动")
        check(Planner.reject(item(home + "/Library/Caches/not-there"), app: app)?.gate == "路径形态", "不存在的路径不动")
        check(Planner.reject(item(home + "/Library/Caches/target-dir/inside.txt"), app: app) == nil, "样本里的普通文件可以通过")

        // 父子同时勾选：只留父
        let parent = item(home + "/Library/Caches/target-dir")
        let child = item(home + "/Library/Caches/target-dir/inside.txt")
        let (ok, rejected) = Planner.preflight([parent, child], apps: apps)
        check(ok.count == 1 && ok[0].path == parent.path, "父子同时勾选时只留父目录")
        check(rejected.contains { $0.gate == "不误伤" }, "子目录被拦下并写明原因")

        // 两个应用勾了同一个路径
        let first = item(home + "/Library/Caches/com.example.fake", appPath: apps[0].path)
        let second = item(home + "/Library/Caches/com.example.fake", appPath: apps[1].path)
        let (ok2, rejected2) = Planner.preflight([first, second], apps: apps)
        check(ok2.isEmpty, "两个应用都勾同一路径时一条都不删")
        check(rejected2.contains { $0.gate == "不误伤" }, "并写明原因")
    }

    // MARK: - 执行

    private static func checkRemoval() -> [String] {
        section("执行与复核")
        let apps = AppScanner.scan()
        guard let fake = apps.first(where: { $0.bundleID == "com.example.fake" }) else { return [] }
        let planned = Planner.build(apps: [fake], all: apps)
        let (ok, _) = Planner.preflight(planned.items, apps: [fake])
        let outcome = Remover.execute(items: ok, skipped: planned.skipped, apps: [fake])

        check(outcome.totalRemoved > 0, "移除了 \(outcome.totalRemoved) 项")
        check(!FileManager.default.fileExists(atPath: Paths.home + "/Library/Containers/com.example.fake"), "容器已移除")
        check(!FileManager.default.fileExists(atPath: fake.path), "应用本体已移除")
        check(!FileManager.default.fileExists(atPath: Paths.system("/Library/Application Support/com.example.fake")),
              "系统级残留已移除（走批处理脚本）")
        check(FileManager.default.fileExists(atPath: Paths.home + "/Library/Containers/com.example.other"),
              "别的应用的容器没被动")
        check(FileManager.default.fileExists(atPath: Paths.home + "/Library/Application Support/Unverified"),
              "拿不准的目录没被动")
        check(FileManager.default.fileExists(atPath: Paths.home + "/Documents/paper.txt"), "用户文稿没被动")

        let log = outcome.logPath
        let logText = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        check(!logText.isEmpty, "日志已写入 \(Format.short(log))")
        check(logText.contains("com.example.fake"), "日志里有被删的路径")
        check(logText.contains("skipped"), "被跳过的条目也写进了日志（有账）")
        let trashEntries = (try? FileManager.default.contentsOfDirectory(atPath: Paths.trash)) ?? []
        check(!trashEntries.isEmpty, "进废纸篓的条目在样本废纸篓里：\(trashEntries.count) 个")
        check(outcome.allFailures.isEmpty, "复核没有失败项（实际 \(outcome.allFailures.count)）")
        // 注入检查：把带引号的路径交给批处理脚本，删对了、没误伤别处
        let trickyPath = Paths.system("/Library/Application Support/it's a \"test\"")
        let trickyItem = PlanItem(appPath: fake.path, appName: fake.name, path: trickyPath,
                                  bytes: 10, kind: .systemLibrary, match: .appName, needsAdmin: true, checked: true)
        _ = Remover.execute(items: [trickyItem], apps: [fake])
        check(!FileManager.default.fileExists(atPath: trickyPath), "带引号与空格的路径删对了（转义有效）")
        check(FileManager.default.fileExists(atPath: root + "/decoy-keep.txt"), "没有误删别的东西")
        check(!logText.contains("Unverified"), "被拦下的目录没有出现在日志里")
        return logText.split(separator: "\n").compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let record = try? JSONDecoder().decode(RemovalRecord.self, from: data) else { return nil }
            return record.result == "ok" ? record.path : nil
        }
    }

    /// 横向断言：这次自检真正删掉/移走的每一条路径都必须在样本目录里。
    private static func checkNoStrayDeletion(_ removed: [String]) {
        section("横向检查")
        let stray = removed.filter { !$0.hasPrefix(root) }
        check(removed.count > 5, "记录到 \(removed.count) 条已删路径")
        check(stray.isEmpty, "每一条都在样本目录里，没碰真系统\(stray.isEmpty ? "" : "：\(stray)")")
    }
}

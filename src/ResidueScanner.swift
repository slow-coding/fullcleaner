// 找出一个应用散落在系统各处的残留。
// 匹配靠三样东西：bundle id（含前缀）、签名里声明的 App Group / iCloud 容器、包内自启项的 label。
// 只有少数几类目录允许按"应用名"匹配（应用支持、缓存、日志），这类会在界面上标出来，让人自己看一眼。

import Foundation

enum ResidueScanner {

    /// 找一条残留。
    struct Hit {
        var path: String
        var kind: ResidueKind
        var how: MatchHow
        var bytes: Int64
        var note: String = ""
        var modified: Date?
    }

    static func residues(for app: AppItem, measure: Bool = true, stop: StopFlag? = nil) -> [Hit] {
        var hits: [Hit] = []
        let matcher = Matcher(app: app)
        let canTouchProtected = Permissions.fullDiskAccessGranted

        func add(_ root: String, _ kind: ResidueKind, _ nameMatching: Bool,
                 stripSuffix: Bool = false, prefixName: Bool = false, label: String? = nil) {
            collect(&hits, root: root, kind: kind, matcher: matcher, stop: stop, measure: measure,
                    canTouchProtected: canTouchProtected,
                    nameMatching: nameMatching, stripSuffix: stripSuffix, prefixName: prefixName, label: label)
        }

        // 没有完全磁盘访问时：iCloud Drive 一碰就弹窗，整段跳过（不打扰用户）
        if canTouchProtected {
            add(Paths.library + "/Mobile Documents", .iCloudContainer, true)
        }

        // 用户级
        add(Paths.library + "/Containers", .container, false)
        add(Paths.library + "/Group Containers", .groupContainer, false)
        add(Paths.library + "/Application Scripts", .appScripts, false)
        add(Paths.library + "/Preferences", .preferences, true, stripSuffix: true)
        add(Paths.library + "/Preferences/ByHost", .preferences, false, stripSuffix: true, label: "偏好（按主机）")
        add(Paths.library + "/Saved Application State", .savedState, false)
        add(Paths.library + "/Caches", .cache, true)
        add(Paths.library + "/HTTPStorages", .httpStorage, false)
        add(Paths.library + "/WebKit", .webkit, false)
        add(Paths.library + "/Application Support", .applicationSupport, true)
        add(Paths.library + "/Application Support/CrashReporter", .crashReporter, true, prefixName: true)
        add(Paths.library + "/Logs", .logs, true)
        add(Paths.library + "/Logs/DiagnosticReports", .logs, true, prefixName: true, label: "崩溃日志")
        add(Paths.library + "/Autosave Information", .savedState, true)
        add(Paths.library + "/LaunchAgents", .launchAgent, false, stripSuffix: true)

        // 系统级（需要管理员）
        add(Paths.system("/Library/Application Support"), .systemLibrary, true)
        add(Paths.system("/Library/Caches"), .systemLibrary, true)
        add(Paths.system("/Library/Logs"), .systemLibrary, true)
        add(Paths.system("/Library/Preferences"), .systemLibrary, true, stripSuffix: true)
        add(Paths.system("/Library/LaunchAgents"), .launchAgent, false, stripSuffix: true)
        add(Paths.system("/Library/LaunchDaemons"), .launchAgent, false, stripSuffix: true)
        add(Paths.system("/Library/PrivilegedHelperTools"), .helperTool, false)

        // 安装包收据
        for receipt in receipts() where matcher.matchesReceipt(receipt) {
            hits.append(Hit(path: receipt, kind: .packageReceipt, how: .packageReceipt, bytes: 0,
                            note: "pkgutil --forget \(receipt)"))
        }

        // 去掉重复与相互包含（父目录已经在清单里，子项没有意义）
        return dedupe(hits)
    }

    // MARK: - 目录扫描

    private static func collect(_ hits: inout [Hit], root: String, kind: ResidueKind, matcher: Matcher,
                                stop: StopFlag?, measure: Bool, canTouchProtected: Bool,
                                nameMatching: Bool, stripSuffix: Bool = false,
                                prefixName: Bool = false, label: String? = nil) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root) else { return }
        Trace.mark("root \(root)")
        let entries = (try? manager.contentsOfDirectory(atPath: root)) ?? []
        for entry in entries.sorted() {
            if stop?.stopped == true { return }
            guard !entry.hasPrefix(".") else { continue }
            let stem = stripSuffix ? (entry as NSString).deletingPathExtension : entry
            guard let how = matcher.match(stem, kind: kind, nameMatching: nameMatching, prefixName: prefixName) else { continue }
            let path = root + "/" + entry
            // 自启项再多问一句：plist 里必须提到这个应用，避免同名 label 误伤
            if kind == .launchAgent, !launchItemBelongsTo(app: matcher.app, path: path) { continue }
            var note = label.map { "\($0)：\(how.explain)" } ?? how.explain
            if kind == .groupContainer { note += " 这个目录由同开发者的多个应用共享，先确认里面没有别的应用在用。" }
            if kind == .iCloudContainer { note += " 删掉会同步到你登录同一 Apple ID 的其他设备。" }
            let needsFDA = (kind == .container || kind == .groupContainer || kind == .iCloudContainer)
            let canMeasure = measure && (!needsFDA || canTouchProtected)
            if needsFDA && !canTouchProtected {
                note += " 体积要完全磁盘访问才能量（现在没给，所以留空）。"
            }
            hits.append(Hit(path: path, kind: kind, how: how,
                            bytes: canMeasure ? Sizer.bytes(of: path, stop: stop) : 0,
                            note: note, modified: Sizer.modified(of: path)))
        }
    }

    /// 自启项的 plist 里要能看到这个应用的路径或 bundle id，才算它的。
    private static func launchItemBelongsTo(app: AppItem, path: String) -> Bool {
        guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { return true }
        let text = plist.description
        return text.contains(app.bundleID) || text.contains(app.path) || text.contains(app.name)
    }

    /// 包收据只要问一次系统：每个应用都 spawn 一次 pkgutil 太亏（152 个应用就是 152 次）。
    private static var cachedReceipts: [String]?

    private static func receipts() -> [String] {
        if let cachedReceipts { return cachedReceipts }
        let list = loadReceipts()
        cachedReceipts = list
        return list
    }

    private static func loadReceipts() -> [String] {
        if let override = ProcessInfo.processInfo.environment["FULLCLEANER_PKG_LIST"], !override.isEmpty {
            return override.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let (status, output) = Shell.run("/usr/sbin/pkgutil", ["--pkgs"], timeout: 20)
        guard status == 0 else { return [] }
        return output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 父子目录同时命中时只留父目录。
    static func dedupe(_ hits: [Hit]) -> [Hit] {
        var sorted = hits.sorted { $0.path.count < $1.path.count }
        var kept: [Hit] = []
        for hit in sorted {
            if kept.contains(where: { hit.path == $0.path || hit.path.hasPrefix($0.path + "/") }) { continue }
            kept.append(hit)
        }
        sorted = kept
        return sorted.sorted { a, b in
            if a.kind == b.kind { return a.path < b.path }
            return kindOrder(a.kind) < kindOrder(b.kind)
        }
    }

    private static func kindOrder(_ kind: ResidueKind) -> Int {
        ResidueKind.allCases.firstIndex(of: kind) ?? 99
    }

    // MARK: - 匹配

    struct Matcher {
        let app: AppItem
        private let id: String
        private let name: String
        private let executable: String

        init(app: AppItem) {
            self.app = app
            self.id = app.bundleID.lowercased()
            self.name = app.name.lowercased()
            self.executable = app.executableName.lowercased()
        }

        /// stem 是去掉扩展名之后的条目名。
        func match(_ stem: String, kind: ResidueKind, nameMatching: Bool, prefixName: Bool) -> MatchHow? {
            let value = stem.lowercased()
            if value == id { return .exactID }
            if value.hasPrefix(id + ".") || value.hasPrefix(id + "-") { return .idPrefix }
            if value == "group." + id || value.hasPrefix("group." + id + ".") { return .appGroup }
            for group in app.appGroups {
                let lower = group.lowercased()
                if value == lower || value == "group." + lower || value.hasPrefix(lower + ".") { return .appGroup }
            }
            for container in app.iCloudContainers {
                let lower = container.lowercased()
                if value == lower || value.hasPrefix(lower + ".") { return .exactID }
                if value == iCloudDirectoryName(container) { return .exactID }
            }
            if value == iCloudDirectoryName(app.bundleID) || value == "icloud." + id { return .exactID }
            for label in app.loginItemLabels {
                let lower = label.lowercased()
                if value == lower || value.hasPrefix(lower + ".") { return .loginItem }
            }
            guard nameMatching, !name.isEmpty, !kind.riskyNameMatchSkipped else { return nil }
            if value == name { return .appName }
            if prefixName, value.hasPrefix(name + "_") || value.hasPrefix(name + "-") { return .appName }
            if value == executable || (prefixName && value.hasPrefix(executable + "_")) { return .appName }
            return nil
        }

        func matchesReceipt(_ receipt: String) -> Bool {
            let value = receipt.lowercased()
            guard !id.isEmpty else { return false }
            return value == id || value.hasPrefix(id + ".") || value.contains("." + id + ".") || value.hasSuffix("." + id)
        }

        /// iCloud 容器在 iCloud Drive 里的目录名：把点换成 ~，前面加 iCloud~。
        /// 比的是小写形式：文件名大小写不能想当然（iCloud~ 这种写法最容易漏）。
        private func iCloudDirectoryName(_ container: String) -> String {
            var value = container
            if value.hasPrefix("iCloud.") { value = String(value.dropFirst("iCloud.".count)) }
            return ("iCloud~" + value.replacingOccurrences(of: ".", with: "~")).lowercased()
        }
    }
}

private extension ResidueKind {
    /// 名字匹配在容器类目录上不可靠（容器名一定是 id 形态），这几类一律不按名字找。
    var riskyNameMatchSkipped: Bool {
        switch self {
        case .container, .groupContainer, .appScripts, .httpStorage, .webkit, .savedState, .helperTool: return true
        default: return false
        }
    }
}

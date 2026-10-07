// 执行层：退出应用 → 重置系统权限记录 → 删除（默认进废纸篓）→ 逐条复核 → 记日志。
// 规则：只删清单里过了闸门的东西；删完必须复核，,路径还在就如实报告失败。
// 需要管理员的条目攒成一次批处理，只弹一次密码框。

import Foundation
import AppKit

struct RemovalRecord: Codable {
    var time: String
    var app: String
    var bundleID: String
    var path: String
    var kind: String
    var bytes: Int64
    var mode: String        // trash / delete / forget / skipped
    var result: String      // ok / failed
    var trashPath: String
    var detail: String
}

struct AppOutcome {
    var appPath: String = ""
    var appName: String
    var removedCount: Int = 0
    var removedBytes: Int64 = 0
    var failures: [Rejection] = []
    var notes: [String] = []
}

struct Outcome {
    var perApp: [AppOutcome] = []
    var skippedCount: Int = 0
    var logPath: String = ""
    var totalBytes: Int64 { perApp.reduce(0) { $0 + $1.removedBytes } }
    var totalRemoved: Int { perApp.reduce(0) { $0 + $1.removedCount } }
    var allFailures: [Rejection] { perApp.flatMap { $0.failures } }
    var notes: [String] { perApp.flatMap { $0.notes } }
}

enum Remover {

    typealias Progress = (String) -> Void

    /// 移到废纸篓的实现。自检里换成搬到样本目录下的 .Trash，
    /// 免得把测试文件丢进真废纸篓里。
    static var trashHandler: ((URL) throws -> URL?) = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    // MARK: - 退出应用

    /// 退出这个应用和它的帮助程序。退了返回 true；退不掉返回 false 并说明原因。
    @discardableResult
    static func quit(_ app: AppItem, onStep: Progress? = nil, timeout: TimeInterval = 5) -> (ok: Bool, detail: String) {
        if Sandbox.isSelfTest { return (true, "自检：跳过退出应用的步骤") }
        var targets: [NSRunningApplication] = []
        let ids = Set([app.bundleID] + app.nestedBundleIDs)
        for running in NSWorkspace.shared.runningApplications {
            if let identifier = running.bundleIdentifier, ids.contains(identifier) {
                targets.append(running)
                continue
            }
            // 从应用包里启动的进程（帮助程序常常没有独立 id 可见）
            if let url = running.bundleURL, url.path.hasPrefix(app.path + "/") {
                targets.append(running)
            }
        }
        if targets.isEmpty { return (true, t("Nothing was running")) }

        onStep?("正在退出 \(app.name)…")
        for process in targets { process.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if targets.allSatisfy({ $0.isTerminated }) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let stubborn = targets.filter { !$0.isTerminated }
        if !stubborn.isEmpty {
            for process in stubborn { process.forceTerminate() }
            let hardDeadline = Date().addingTimeInterval(2)
            while Date() < hardDeadline && stubborn.contains(where: { !$0.isTerminated }) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }
        // 自带的自启项：把服务卸掉（用户级的不用管理员）
        unloadServices(app: app, onStep: onStep)

        let stillRunning = targets.filter { !$0.isTerminated }
        if stillRunning.isEmpty { return (true, t("Quit")) }
        return (false, "还有 \(stillRunning.count) 个进程没退掉（可以在活动监视器里退出，或者重启后再卸）")
    }

    /// 卸掉这个应用注册的自启项与常驻服务。
    static func unloadServices(app: AppItem, onStep: Progress? = nil) {
        guard !Sandbox.isSelfTest else { return }
        var labels = Set(app.loginItemLabels)
        let (_, listing) = Shell.run("/bin/launchctl", ["list"], timeout: 15)
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let label = parts.last.map(String.init), !label.isEmpty else { continue }
            if label.contains(app.bundleID) || app.nestedBundleIDs.contains(where: { label.contains($0) }) {
                labels.insert(label)
            }
        }
        guard !labels.isEmpty else { return }
        let uid = getuid()
        for label in labels.sorted() {
            onStep?("卸掉自启项 \(label)…")
            Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], timeout: 15)
        }
    }

    // MARK: - 权限记录

    /// 重置系统里的权限记录（辅助功能、输入监控、完全磁盘访问…）。不重置的话，重装后还留着旧条目。
    static func resetPermissions(_ app: AppItem, onStep: Progress? = nil) -> [String] {
        if Sandbox.tccDisabled || Sandbox.isSelfTest { return ["自检：跳过权限记录重置"] }
        var notes: [String] = []
        for identifier in [app.bundleID] + app.nestedBundleIDs {
            let (status, _) = Shell.run("/usr/bin/tccutil", ["reset", "All", identifier], timeout: 30)
            if status == 0 { notes.append("重置了权限记录：\(identifier)") }
        }
        if !notes.isEmpty { onStep?("重置权限记录（\(notes.count) 条）") }
        // 偏好设置的域也一并清掉，否则 cfprefsd 可能把 plist 又写回来
        for identifier in [app.bundleID] + app.nestedBundleIDs {
            Shell.run("/usr/bin/defaults", ["delete", identifier], timeout: 15)
        }
        return notes
    }

    // MARK: - 删除

    /// 执行清单。返回结果 + 日志路径。
    static func execute(items: [PlanItem], skipped: [Skipped] = [], apps: [AppItem], onStep: Progress? = nil) -> Outcome {
        var outcome = Outcome()
        let byApp = Dictionary(grouping: items, by: { $0.appPath })
        let appByPath = Dictionary(uniqueKeysWithValues: apps.map { ($0.path, $0) })

        let logFile = Paths.logDirectory + "/" + timestamp() + "-uninstall.jsonl"
        var records: [RemovalRecord] = []
        outcome.skippedCount = skipped.count
        // 被跳过的条目也进日志：数目报给用户，明细留在这儿（不删的东西也要有账）
        for skip in skipped {
            records.append(RemovalRecord(time: timestamp(), app: skip.appName, bundleID: "", path: skip.path,
                                         kind: "skipped", bytes: 0, mode: "skipped", result: "skipped",
                                         trashPath: "", detail: skip.reason))
        }

        for app in apps {
            var result = AppOutcome(appPath: app.path, appName: app.name)
            let appItems = byApp[app.path] ?? []
            guard !appItems.isEmpty else { outcome.perApp.append(result); continue }

            // 1. 退出应用；退不掉就不动它（半个应用删了比不删更糟）
            let quitResult = quit(app, onStep: onStep)
            if !quitResult.ok {
                result.failures.append(Rejection(path: app.path, appName: app.name,
                                                 reason: quitResult.detail, gate: t("App already quit")))
                outcome.perApp.append(result)
                continue
            }

            // 2. 权限记录（要在删文件之前做，删完就找不到包内的子程序 id 了）
            result.notes.append(contentsOf: resetPermissions(app, onStep: onStep))

            // 3. 删除：能进废纸篓的进废纸篓，需要管理员的攒批
            var privileged: [PlanItem] = []
            for item in appItems {
                if item.kind == .packageReceipt || item.needsAdmin {
                    privileged.append(item)
                    continue
                }
                if let failure = trashOne(item, records: &records, app: app) {
                    result.failures.append(failure)
                    continue
                }
                result.removedCount += 1
                result.removedBytes += item.bytes
            }

            if !privileged.isEmpty {
                onStep?("需要管理员权限：\(privileged.count) 项（可能会弹一次密码框）")
                let (failures, removed) = privilegedBatch(privileged, app: app, records: &records)
                result.failures.append(contentsOf: failures)
                result.removedCount += removed.count
                result.removedBytes += removed.reduce(Int64(0)) { $0 + $1.bytes }
            }

            // 4. 复核：清单里每条都再看一眼
            for item in appItems {
                let stillThere = FileManager.default.fileExists(atPath: item.path)
                if stillThere, item.kind != .packageReceipt,
                   !result.failures.contains(where: { $0.path == item.path }) {
                    result.failures.append(Rejection(path: item.path, appName: app.name,
                                                     reason: t("Still there after deletion"), gate: t("Verification")))
                }
            }
            outcome.perApp.append(result)
        }

        // 写日志：清单 + 结果，含废纸篓里的落点
        let encoder = JSONEncoder()
        let lines = records.compactMap { record -> String? in
            guard let data = try? encoder.encode(record) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(toFile: logFile, atomically: true, encoding: .utf8)
        outcome.logPath = logFile
        _ = appByPath
        return outcome
    }

    /// 移到废纸篓。失败就返回原因（不改用强删——拿不准就不动）。
    private static func trashOne(_ item: PlanItem, records: inout [RemovalRecord], app: AppItem) -> Rejection? {
        var trashPath = ""
        do {
            trashPath = (try trashHandler(URL(fileURLWithPath: item.path)))?.path ?? ""
        } catch {
            records.append(RemovalRecord(time: timestamp(), app: app.name, bundleID: app.bundleID, path: item.path,
                                         kind: item.kind?.rawValue ?? "bundle", bytes: item.bytes, mode: "trash",
                                         result: "failed", trashPath: "", detail: error.localizedDescription))
            return Rejection(path: item.path, appName: app.name, reason: error.localizedDescription, gate: t("Move to Trash"))
        }
        records.append(RemovalRecord(time: timestamp(), app: app.name, bundleID: app.bundleID, path: item.path,
                                     kind: item.kind?.rawValue ?? "bundle", bytes: item.bytes, mode: "trash",
                                     result: "ok", trashPath: trashPath, detail: ""))
        return nil
    }

    /// 需要管理员的条目：攒成一个脚本，跑一次（只弹一次密码框）。
    private static func privilegedBatch(_ items: [PlanItem], app: AppItem,
                                        records: inout [RemovalRecord]) -> (failures: [Rejection], removed: [PlanItem]) {
        var script = "#!/bin/sh\n"
        for item in items {
            if item.kind == .packageReceipt {
                if Sandbox.isSelfTest { continue }   // 自检不碰真的 pkgutil 收据
                script += "if /usr/sbin/pkgutil --forget \(shellQuote(item.path)) >/dev/null 2>&1; then echo \"OK|\(marker(item))\"\n"
                script += "else echo \"FAIL|\(marker(item))\"; fi\n"
            } else {
                script += "if /bin/rm -rf -- \(shellQuote(item.path)); then echo \"OK|\(marker(item))\"\n"
                script += "else echo \"FAIL|\(marker(item))\"; fi\n"
            }
        }
        let temp = NSTemporaryDirectory() + "fullcleaner-\(UUID().uuidString).sh"
        try? script.write(toFile: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: temp) }

        let output: String
        let status: Int32
        if Sandbox.adminDisabled {
            // 自检：样本目录里的东西属于当前用户，直接跑同一个脚本（验证脚本本身，不要密码）
            (status, output) = Shell.run("/bin/sh", [temp], timeout: 120)
        } else {
            (status, output) = Shell.run("/usr/bin/osascript",
                                         ["-e", "do shell script \"/bin/sh \(temp)\" with administrator privileges"],
                                         timeout: 300)
        }
        let failed = Set(output.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("FAIL|") else { return nil }
            return String(line.dropFirst("FAIL|".count))
        })
        let succeeded = Set(output.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("OK|") else { return nil }
            return String(line.dropFirst("OK|".count))
        })

        var failures: [Rejection] = []
        var removed: [PlanItem] = []
        for item in items {
            let key = marker(item)
            let why = status == 0 ? t("the command failed") : (status == -1 ? t("the administrator prompt was not granted (maybe cancelled)") : t("the command failed"))
            if succeeded.contains(key) {
                removed.append(item)
                records.append(RemovalRecord(time: timestamp(), app: app.name, bundleID: app.bundleID, path: item.path,
                                             kind: item.kind?.rawValue ?? "bundle", bytes: item.bytes,
                                             mode: item.kind == .packageReceipt ? "forget" : "delete",
                                             result: "ok", trashPath: "", detail: ""))
            } else if item.kind == .packageReceipt && Sandbox.isSelfTest {
                // 自检不跑 pkgutil，记为跳过
                records.append(RemovalRecord(time: timestamp(), app: app.name, bundleID: app.bundleID, path: item.path,
                                             kind: "packageReceipt", bytes: 0, mode: "skipped",
                                             result: "ok", trashPath: "", detail: "自检：跳过 pkgutil --forget"))
            } else if failed.contains(key) || !succeeded.contains(key) {
                failures.append(Rejection(path: item.path, appName: app.name, reason: why, gate: t("Administrator action")))
                records.append(RemovalRecord(time: timestamp(), app: app.name, bundleID: app.bundleID, path: item.path,
                                             kind: item.kind?.rawValue ?? "bundle", bytes: item.bytes,
                                             mode: item.kind == .packageReceipt ? "forget" : "delete",
                                             result: "failed", trashPath: "", detail: why))
            }
        }
        return (failures, removed)
    }

    // MARK: - 小工具

    private static func marker(_ item: PlanItem) -> String { item.path }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

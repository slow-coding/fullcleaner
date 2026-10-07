// 入口：正常启动开界面；另外有几个不打开界面的用法（自检、出报告、出图）。
//   fullcleaner --selftest                     在临时样本目录里跑完整的判据与删除流程
//   fullcleaner --list [--json]                列出已安装应用（只读）
//   fullcleaner --plan <名字|bundle id> [--json] 打印一个应用的卸载清单（只读，不删东西）
//   fullcleaner --uninstall <名字|bundle id> --yes  按同一套闸门执行卸载（默认进废纸篓）
//   fullcleaner --render <out.png>             把界面渲染成图，不需要截屏权限

import SwiftUI
import AppKit

@main
struct Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--help") || args.contains("-h") { CLI.usage(); exit(0) }
        if args.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }
        if let index = args.firstIndex(of: "--lang"), index + 1 < args.count,
           let lang = Lang(rawValue: args[index + 1]) { Str.use(lang) }
        if args.contains("--permissions") { exit(CLI.permissions(json: args.contains("--json"))) }
        if args.contains("--list") { exit(CLI.list(json: args.contains("--json"))) }
        if let index = args.firstIndex(of: "--plan"), index + 1 < args.count {
            exit(CLI.plan(target: args[index + 1], json: args.contains("--json")))
        }
        if let index = args.firstIndex(of: "--uninstall"), index + 1 < args.count {
            exit(CLI.uninstall(target: args[index + 1], confirmed: args.contains("--yes")))
        }
        if let index = args.firstIndex(of: "--render-permissions"), index + 1 < args.count {
            _ = NSApplication.shared
            var ok = false
            if #available(macOS 14.0, *) {
                ok = MainActor.assumeIsolated { RenderDemo.renderPermissions(to: args[index + 1]) }
            }
            print(ok ? t("Rendered the permissions panel to %@", args[index + 1]) : t("Render failed"))
            exit(ok ? 0 : 1)
        }
        if let index = args.firstIndex(of: "--render"), index + 1 < args.count {
            _ = NSApplication.shared
            var ok = false
            if #available(macOS 14.0, *) {
                ok = MainActor.assumeIsolated { RenderDemo.renderMain(to: args[index + 1]) }
            }
            print(ok ? t("Rendered the interface to %@", args[index + 1]) : t("Render failed"))
            exit(ok ? 0 : 1)
        }
        if let index = args.firstIndex(of: "--render-review"), index + 1 < args.count {
            _ = NSApplication.shared
            var ok = false
            if #available(macOS 14.0, *) {
                ok = MainActor.assumeIsolated { RenderDemo.renderReview(to: args[index + 1]) }
            }
            print(ok ? t("Rendered the plan to %@", args[index + 1]) : t("Render failed"))
            exit(ok ? 0 : 1)
        }
        if let index = args.firstIndex(of: "--render-result"), index + 1 < args.count {
            _ = NSApplication.shared
            var ok = false
            if #available(macOS 14.0, *) {
                ok = MainActor.assumeIsolated { RenderDemo.renderResult(to: args[index + 1]) }
            }
            print(ok ? t("Rendered the result sheet to %@", args[index + 1]) : t("Render failed"))
            exit(ok ? 0 : 1)
        }
        FullCleanerApp.main()
    }
}

struct FullCleanerApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("FullCleaner") {
            ContentView(state: state)
        }
        .defaultSize(width: 820, height: 640)
        .windowResizability(.contentMinSize)     // 只有用户能改窗口大小，内容变化不带动它
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

enum CLI {

    static func usage() {
        print("""
        FullCleaner — remove a macOS app and everything it left behind

        Usage:
          fullcleaner --list [--json]                    list installed apps (read-only)
          fullcleaner --plan <name|bundle id> [--json]   print the removal plan for one app (read-only)
          fullcleaner --uninstall <name|bundle id> --yes execute the plan (Trash by default)
          fullcleaner --permissions [--json]             system permission status (two items)
          fullcleaner --lang <en|zh>                     switch interface language
          fullcleaner --selftest                         run the self test in a temp sandbox
          fullcleaner --render <out.png>                 render the interface to a PNG
          fullcleaner --render-review <out.png>          render the removal plan
          fullcleaner --render-permissions <out.png>     render the permissions panel
          fullcleaner --render-result <out.png>          render the result sheet
          fullcleaner --help                             this text

        No arguments opens the interface. Deletion goes to the Trash; root-owned items
        take one administrator prompt. Source and docs: github.com/slow-coding/fullcleaner (MIT)
        """)
    }

    /// 找出用户说的那个应用：路径、bundle id、或者名字（唯一匹配才认）。
    static func locate(_ target: String, apps: [AppItem]) -> AppItem? {
        if target.hasSuffix(".app"), let hit = apps.first(where: { $0.path == target }) { return hit }
        if let hit = apps.first(where: { $0.bundleID == target }) { return hit }
        let matches = apps.filter { $0.name.lowercased() == target.lowercased() }
        if matches.count == 1 { return matches[0] }
        let partial = apps.filter { $0.name.lowercased().contains(target.lowercased()) }
        return partial.count == 1 ? partial[0] : nil
    }

    /// 权限现状：给用户看，也可以给脚本用。
    static func permissions(json: Bool) -> Int32 {
        let rows = Permissions.all()
        if json {
            let payload = rows.map { ["permission": $0.permission.rawValue, "title": $0.permission.title,
                                      "status": "\($0.status)", "settings": $0.permission.settingsURL] }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            return rows.allSatisfy { $0.status == .granted } ? 0 : 1
        }
        print(t("Permissions (this tool only uses these)"))
        for row in rows {
            let mark = row.status == .granted ? "✓" : (row.status == .missing ? "✗" : "?")
            print("  \(mark) \(row.permission.title)  \(row.status.label)")
            if row.status != .granted { print("      \(row.permission.settingsHint)") }
        }
        return rows.allSatisfy { $0.status == .granted } ? 0 : 1
    }

    static func list(json: Bool) -> Int32 {
        let apps = AppScanner.scan()
        if json {
            let payload: [[String: Any]] = apps.map { app in
                [
                    "name": app.name, "path": app.path, "bundleID": app.bundleID, "version": app.version,
                    "bytes": app.bytes, "mas": app.isMAS, "rootOwned": app.rootOwned, "protected": app.protected,
                    "lastOpened": app.lastOpened.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                    "openCount": app.openCount ?? -1,
                    "appGroups": app.appGroups, "iCloudContainers": app.iCloudContainers,
                    "nestedBundleIDs": app.nestedBundleIDs,
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            return 0
        }
        print(t("%d apps installed · %@ total", apps.count, Format.size(apps.reduce(0) { $0 + $1.bytes })))
        print("")
        for app in apps.sorted(by: { $0.bytes > $1.bytes }) {
            var marks: [String] = []
            if app.protected { marks.append("系统") }
            if app.isMAS { marks.append("App Store") }
            if app.rootOwned && !app.protected { marks.append("root") }
            let suffix = marks.isEmpty ? "" : "  [\(marks.joined(separator: " "))]"
            let usage = "\(Format.age(app.lastOpened)) · \(app.openCount.map { "\($0) 次" } ?? "—")"
            print(String(format: "%10@  %@%@", Format.size(app.bytes) as NSString, app.name as NSString, suffix as NSString))
            print(String(format: "            %@  ·  %@", app.bundleID as NSString, usage as NSString))
        }
        return 0
    }

    static func plan(target: String, json: Bool) -> Int32 {
        let apps = AppScanner.scan()
        guard let app = locate(target, apps: apps) else {
            print(t("Not found: “%@”. Try --list to see what is installed.", target))
            return 2
        }
        let planned = Planner.build(apps: [app], all: apps)
        let items = planned.items
        let (ok, rejected) = Planner.preflight(items, apps: [app])

        if json {
            let payload: [String: Any] = [
                "app": ["name": app.name, "path": app.path, "bundleID": app.bundleID, "bytes": app.bytes],
                "items": items.map { item in
                    [
                        "path": item.path, "bytes": item.bytes, "kind": item.kind?.rawValue ?? "bundle",
                        "match": item.match?.rawValue ?? "bundle",
                        "defaultChecked": item.checked, "needsAdmin": item.needsAdmin,
                        "sharedWith": item.sharedWith, "note": item.note,
                    ] as [String: Any]
                },
                "wouldDelete": ok.map { $0.path },
                "skipped": planned.skipped.map { ["path": $0.path, "reason": $0.reason] },
                "rejected": rejected.map { ["path": $0.path, "gate": $0.gate, "reason": $0.reason] },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            return 0
        }

        print("\(app.name)  \(app.version)  \(app.bundleID)")
        print("\(t("App bundle")) \(Format.size(app.bytes)) · \(app.path)")
        print("")
        print(t("Items in the plan (%d, ★ = selected):", items.count))
        for item in items {
            let mark = item.checked ? "★" : " "
            let kind = item.kind.map { "[\($0.label)]" } ?? "[\(t("App bundle"))]"
            print(String(format: "  %@ %10@  %@ %@", mark as NSString, Format.size(item.bytes) as NSString,
                         kind as NSString, Format.path(item.path) as NSString))
            if !item.isAppBundle { print("        \(item.why)") }
        }
        if !planned.skipped.isEmpty {
            print("")
            print(t("Skipped %d items (uncertain, or not safe to remove):", planned.skipped.count))
            for skip in planned.skipped {
                print("  · \(skip.reason) —— \(Format.short(skip.path))")
            }
        }
        if !rejected.isEmpty {
            print("")
            print("被拦下（不会删）：")
            for rejection in rejected {
                print("  · \(rejection.gate)：\(rejection.reason) —— \(Format.short(rejection.path))")
            }
        }
        print("")
        print(t("Would remove %d items · %@; this command only prints the list.", ok.count,
                Format.size(ok.reduce(0) { $0 + $1.bytes })))
        return 0
    }

    static func uninstall(target: String, confirmed: Bool) -> Int32 {
        guard confirmed else {
            print(t("Add --yes to actually delete. Run --plan %@ first to see the list.", target))
            return 64
        }
        let apps = AppScanner.scan()
        guard let app = locate(target, apps: apps) else {
            print(t("Not found: “%@”. Try --list to see what is installed.", target))
            return 2
        }
        let planned = Planner.build(apps: [app], all: apps)
        let (ok, rejected) = Planner.preflight(planned.items, apps: [app])
        if !rejected.isEmpty {
            print(t("Blocked %d items (not deleted):", rejected.count))
            for rejection in rejected { print("  · \(rejection.gate)：\(rejection.reason) —— \(Format.short(rejection.path))") }
        }
        let outcome = Remover.execute(items: ok, apps: [app]) { line in
            FileHandle.standardError.write("\(line)\n".data(using: .utf8)!)
        }
        print("")
        print(t("Removed %d items · %@", outcome.totalRemoved, Format.size(outcome.totalBytes)))
        for result in outcome.perApp {
            for note in result.notes { print("  · \(note)") }
            for failure in result.failures { print("  · " + t("left alone: %@ (%@)", failure.reason, Format.short(failure.path))) }
        }
        print(t("Log: %@", outcome.logPath))
        return outcome.allFailures.isEmpty ? 0 : 1
    }
}

extension Format {
    /// 打印路径时把主目录缩成 ~
    static func path(_ value: String) -> String { short(value) }
}

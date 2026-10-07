// 把界面渲染成 PNG（离屏、不截屏、数据是造的）。
// 用途：改完界面看一眼真实排版与文案。不需要屏幕录制权限，也不会拍到屏幕上的别的东西。
// 用法：fullcleaner --render out.png / --render-review out.png / --render-result out.png

import SwiftUI
import AppKit

enum RenderDemo {

    private static func fakeApp(_ name: String, _ identifier: String, version: String,
                                bytes: Int64, icon: String, system: Bool = false, root: Bool = false,
                                usedDaysAgo: Int = 3, opens: Int = 128) -> AppItem {
        AppItem(path: "/Applications/\(name).app", bundleID: identifier, name: name, version: version,
                bytes: bytes, isSystem: system, isMAS: true, rootOwned: root, executableName: name,
                nestedBundleIDs: [], loginItemLabels: [], appGroups: [], iCloudContainers: [],
                modified: Date().addingTimeInterval(-86_400 * 30),
                lastOpened: Date().addingTimeInterval(-86_400 * Double(usedDaysAgo)), openCount: opens,
                iconPath: icon)
    }

    @MainActor
    static func demoState() -> AppState {
        let state = AppState()
        state.apps = [
            fakeApp("Foo Studio", "com.example.foostudio", version: "2.1", bytes: 486_000_000,
                    icon: "/System/Applications/Calculator.app"),
            fakeApp("Pixel Press", "com.example.pixelpress", version: "5.0.3", bytes: 1_240_000_000,
                    icon: "/System/Applications/Preview.app", usedDaysAgo: 41, opens: 1_204),
            fakeApp("Line Tool", "com.example.linetool", version: "1.4", bytes: 38_000_000,
                    icon: "/System/Applications/TextEdit.app", root: true, usedDaysAgo: 214, opens: 6),
            fakeApp("Calculator", "com.apple.calculator", version: "11.0", bytes: 12_000_000,
                    icon: "/System/Applications/Calculator.app", system: true),
        ]
        state.selection = ["/Applications/Foo Studio.app", "/Applications/Line Tool.app"]
        state.residueCount = ["/Applications/Foo Studio.app": 8, "/Applications/Line Tool.app": 3]
        state.scanning = false
        state.showSystem = true        // 出图时把系统自带那条也画出来，方便核对行的差别
        state.sortKey = .lastOpened
        state.sortAscending = false
        state.suppressAutoStart = true
        return state
    }

    @MainActor
    static func demoPlan(app: AppItem) -> [PlanItem] {
        func item(_ path: String, _ bytes: Int64, _ kind: ResidueKind?, _ match: MatchHow?,
                  admin: Bool = false, note: String = "") -> PlanItem {
            PlanItem(appPath: app.path, appName: app.name, path: path, bytes: bytes,
                     kind: kind, match: match, note: note, needsAdmin: admin, checked: true)
        }
        return [
            item(app.path, app.bytes, nil, nil),
            item("~/Library/Containers/com.example.foostudio", 1_180_000_000, .container, .exactID,
                 note: "目录名与应用的 bundle id 完全一致。"),
            item("~/Library/Preferences/com.example.foostudio.plist", 24_000, .preferences, .exactID),
            item("~/Library/Caches/com.example.foostudio", 96_000_000, .cache, .exactID),
            item("~/Library/Application Support/Foo Studio", 240_000_000, .applicationSupport, .appName,
                 note: "判据：文件里写到了 com.example.foostudio。"),
            item("~/Library/Group Containers/group.com.example.studio", 720_000_000, .groupContainer, .appGroup),
            item("/Library/LaunchDaemons/com.example.foostudio.helper.plist", 2_000, .launchAgent, .idPrefix, admin: true),
        ]
    }

    @MainActor
    static func demoSkipped() -> [Skipped] {
        [
            Skipped(path: "~/Library/Group Containers/group.com.example.shared", appName: "Foo Studio",
                    reason: "还有别的应用在用（Pixel Press）"),
            Skipped(path: "~/Library/Application Support/Foo Studio Backups", appName: "Foo Studio",
                    reason: "只有名字像，没有证据"),
        ]
    }

    @MainActor
    static func renderPermissions(to path: String) -> Bool {
        let state = demoState()
        state.permissionRows = [
            PermissionRow(permission: .fullDiskAccess, status: .granted),
            PermissionRow(permission: .appManagement, status: .missing, checking: true),
        ]
        state.sheet = .permissions
        return render(AnyView(PermissionsSheet(state: state)), width: 580, height: 320, to: path)
    }

    @MainActor
    static func renderMain(to path: String) -> Bool {
        let state = demoState()
        return render(AnyView(ContentView(state: state)), width: 760, height: 640, to: path)
    }

    @MainActor
    static func renderReview(to path: String) -> Bool {
        let state = demoState()
        guard let app = state.apps.first else { return false }
        state.plan = demoPlan(app: app)
        state.skipped = demoSkipped()
        state.rejected = []
        state.sheet = .review
        state.planBuilding = false
        return render(AnyView(ReviewSheet(state: state)), width: 720, height: 640, to: path)
    }

    @MainActor
    static func renderResult(to path: String) -> Bool {
        let state = demoState()
        var outcome = Outcome()
        outcome.logPath = "~/Library/Logs/fullcleaner/20261007-181500-uninstall.jsonl"
        var first = AppOutcome(appName: "Foo Studio")
        first.removedCount = 8
        first.removedBytes = 1_540_000_000
        first.notes = ["重置了权限记录：com.example.foostudio",
                       "重置了权限记录：com.example.foostudio.helper",
                       "卸掉自启项 com.example.foostudio.helper"]
        first.failures = [Rejection(path: "~/Library/Caches/com.example.foostudio",
                                    appName: "Foo Studio",
                                    reason: "删完路径还在（还有进程在写）", gate: "复核")]
        var second = AppOutcome(appName: "Line Tool")
        second.removedCount = 3
        second.removedBytes = 38_400_000
        outcome.perApp = [first, second]
        outcome.skippedCount = 2
        state.outcome = outcome
        state.sheet = .result
        return render(AnyView(ResultSheet(state: state)), width: 620, height: 420, to: path)
    }

    @MainActor
    static func render(_ content: AnyView, width: CGFloat, height: CGFloat, to path: String) -> Bool {
        // 底色必须自己画：不画的话透明区域在深色模式下会让白字"消失"
        let canvas = AnyView(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                content
            }
            .frame(width: width, height: height)
        )
        let hosting = NSHostingView(rootView: canvas)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // 真窗口离屏渲染：ImageRenderer 不渲染滚动区里的内容，截出来是空白
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

// 界面状态与流程：扫描应用 → 勾选 → 生成清单 → 确认 → 执行 → 结果。
// 状态与界面分开：界面只读 state，改数据只调这里的方法。

import Foundation
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var apps: [AppItem] = []
    @Published var query: String = "" { didSet { refreshVisibleRows() } }
    @Published var selection: Set<String> = []          // 勾中的应用 path
    @Published var showSystem: Bool = false { didSet { refreshVisibleRows() } }
    @Published var lang: Lang = .en
    @Published var hovered: String?
    @Published private(set) var icons: [String: NSImage] = [:]
    /// 卸载前把图标存一份给结果页用：应用删掉之后就从 apps 里没了，再取就只剩通用图标
    @Published private(set) var resultIcons: [String: NSImage] = [:]
    @Published private(set) var visibleRows: [AppItem] = []
    @Published var sortKey: SortKey = SortKey(rawValue: UserDefaults.standard.string(forKey: "sortKey") ?? "") ?? .size {
        didSet { UserDefaults.standard.set(sortKey.rawValue, forKey: "sortKey"); refreshVisibleRows() }
    }
    @Published var sortAscending: Bool = UserDefaults.standard.object(forKey: "sortAscending") as? Bool ?? false {
        didSet { UserDefaults.standard.set(sortAscending, forKey: "sortAscending"); refreshVisibleRows() }
    }
    @Published var scanning: Bool = true
    @Published var phase: String = t("Scanning installed apps…")
    @Published var scanningLine: String = ""
    @Published var residueCount: [String: Int] = [:]    // 应用 path → 找到几处残留（只数个数，不量体积）

    @Published var sheet: Sheet? = nil
    @Published var plan: [PlanItem] = []
    @Published var skipped: [Skipped] = []
    @Published var rejected: [Rejection] = []
    @Published var planBuilding = false
    @Published var confirmText: String = ""
    @Published var outcome: Outcome? = nil
    @Published var progressLine: String = ""
    @Published var resultPulse = false      // 结果页那个对号的入场动画（SwiftUI 的 @State 在命令行编译下用不了）
    @Published var lastScanFinished: Date? = nil
    @Published var permissionRows: [PermissionRow] = []
    /// 拨了开关但还探不到（TCC 按进程缓存）：面板底部出「重启 FullCleaner」。
    @Published var permissionNeedsRelaunch = false
    /// 点卸载时权限没给全：不当半吊子卸，先把人送回权限面板（见 runUninstall）。
    @Published var uninstallBlocked = false
    @Published var message: String = ""

    enum Sheet: Identifiable {
        case permissions
        case review
        case running
        case result
        var id: String { String(describing: self) }
    }

    private var stopFlag = StopFlag()
    private var stopFlagForCounting = StopFlag()
    private var started = false
    /// 出图时不要真的去扫本机（会把演示数据冲掉）
    var suppressAutoStart = false

    // MARK: - 扫描

    func start() {
        guard !started, !suppressAutoStart else { return }
        started = true
        refreshPermissions()
        // 第一次打开先把权限面板摆出来：缺权限会直接影响扫描与卸载，讲清楚再干活
        if UserDefaults.standard.bool(forKey: "permissionsPromptShown") == false {
            UserDefaults.standard.set(true, forKey: "permissionsPromptShown")
            if !Permissions.allGranted { sheet = .permissions }
        }
        scan()
    }

    func scan() {
        stopFlag = StopFlag()
        scanning = true
        phase = t("Scanning installed apps…")
        residueCount = [:]
        selection = []
        scanningLine = ""
        visibleRows = []
        let flag = stopFlag
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [AppItem] = []
            var index = 0
            let result = AppScanner.scan(stop: flag) { item in
                found.append(item)
                index += 1
                let done = index
                DispatchQueue.main.async { self.scanningLine = "已找到 \(done) 个 · \(item.name)" }
            }
            DispatchQueue.main.async {
                self.apps = result
                self.cacheIcons(for: result)
                self.refreshVisibleRows()
                self.scanning = false
                self.lastScanFinished = Date()
                self.scanningLine = ""
                self.countResiduesInBackground()
            }
        }
    }

    /// 后台把每个应用的残留处数补齐（表格里那一列要有值）。
    /// 只列目录不量体积，所以很快；一个一个来，不跟界面抢。
    func countResiduesInBackground() {
        let list = apps
        let flag = stopFlagForCounting          // 值捕获：Swift 6 下闭包里不能直接读主 actor 的属性
        DispatchQueue.global(qos: .utility).async {
            for app in list where !app.protected {      // 系统自带应用不数残留：它们不能被卸，而且会去碰 Music 这类路径
                if flag.stopped { return }
                let count = ResidueScanner.residues(for: app, measure: false).count
                DispatchQueue.main.async {
                    if self.residueCount[app.path] == nil { self.residueCount[app.path] = count }
                }
            }
        }
    }

    /// 勾选时立刻补这一条的计数（用户已经在看它了）。
    func countResidues(for app: AppItem) {
        guard residueCount[app.path] == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let count = ResidueScanner.residues(for: app, measure: false).count
            DispatchQueue.main.async { self.residueCount[app.path] = count }
        }
    }

    // MARK: - 列表

    var visible: [AppItem] { visibleRows }

    /// 列表每次变化（搜索、排序、显示系统应用、扫描完成）只重算一次，别在 body 里反复算。
    func refreshVisibleRows() {
        var rows = apps
        if !showSystem { rows = rows.filter { !$0.protected } }
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !text.isEmpty { rows = rows.filter { $0.name.lowercased().contains(text) } }
        visibleRows = SortKey.sorted(rows, by: sortKey, ascending: sortAscending)
    }

    /// 图标一次性取好：NSWorkspace.icon 每帧每行都调会很卡（这是列表不顺滑的主因）。
    private func cacheIcons(for list: [AppItem]) {
        var cache: [String: NSImage] = [:]
        for app in list { cache[app.path] = NSWorkspace.shared.icon(forFile: app.icon) }
        icons = cache
    }

    /// 出图用：把演示数据的图标也先缓存好；结果页那份也要有。
    func cacheIconsForDemo() {
        cacheIcons(for: apps)
        resultIcons = Dictionary(uniqueKeysWithValues: apps.compactMap { app in
            icons[app.path].map { (app.path, $0) }
        })
    }

    func icon(for app: AppItem) -> NSImage {
        icons[app.path] ?? NSWorkspace.shared.icon(forFile: app.icon)
    }

    var selectedApps: [AppItem] { apps.filter { selection.contains($0.path) } }
    var selectedBytes: Int64 { selectedApps.reduce(0) { $0 + $1.bytes } }
    var systemCount: Int { apps.filter { $0.protected }.count }

    func toggle(_ app: AppItem) {
        if selection.contains(app.path) {
            selection.remove(app.path)
        } else {
            guard !app.protected else { return }
            selection.insert(app.path)
            countResidues(for: app)
        }
    }

    func clearSelection() { selection = [] }

    /// 切语言：存下来并立刻重绘（界面上所有字串都是渲染时查表的）。
    func use(_ lang: Lang) {
        self.lang = lang
        Str.use(lang)
        objectWillChange.send()
    }

    // MARK: - 权限

    /// 打开权限面板时刷新一次状态。
    func refreshPermissions() {
        permissionRows = Permissions.all()
    }

    /// 一行点「打开系统设置」：跳过去，后台等系统放行（最多 20 秒），放行自动打勾。
    /// 等不到就说清下一步：macOS 常常要重启应用后权限才生效（旧版只挂个转圈，用户不知道怎么办）。
    func openPermissionSettings(_ permission: Permission) {
        Permissions.openSettings(for: permission)
        permissionNeedsRelaunch = false
        guard let index = permissionRows.firstIndex(where: { $0.permission == permission }) else { return }
        permissionRows[index].checking = true
        Task {
            let granted = await Permissions.waitForGrant(permission)
            await MainActor.run {
                self.refreshPermissions()
                if let index = self.permissionRows.firstIndex(where: { $0.permission == permission }) {
                    self.permissionRows[index].checking = false
                }
                self.permissionNeedsRelaunch = granted != .granted && Permissions.canRelaunch
            }
        }
    }

    /// 「重新检查」：重探一次；都齐了就把重启提醒与卸载拦截都收掉。
    func checkPermissionsAgain() {
        refreshPermissions()
        if Permissions.allGranted {
            permissionNeedsRelaunch = false
            uninstallBlocked = false
        }
    }

    /// 「重启 FullCleaner」：能重启就重启（只有 .app 形态行），否则什么都不做。
    func restartApp() {
        Permissions.relaunch()
    }

    /// 点表头：换列就用该列的默认方向，点同一列则翻转方向。
    func sort(by key: SortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = key.defaultAscending
        }
    }

    // MARK: - 清单

    /// 生成清单：找残留 + 量体积。这步可能慢（容器动辄几个 GB），所以放到后台。
    func buildPlan() {
        let chosen = selectedApps
        guard !chosen.isEmpty else { return }
        planBuilding = true
        sheet = .review
        progressLine = t("Finding leftovers and measuring them…")
        let all = apps
        DispatchQueue.global(qos: .userInitiated).async {
            // 累积变量必须声明在闭包里面：Swift 6 下「闭包里改外面的 var」是错误（CI 的编译器会拦）
            var items: [PlanItem] = []
            var skipped: [Skipped] = []
            for app in chosen {
                var found = 0
                DispatchQueue.main.async { self.progressLine = "正在扫描 \(app.name)…" }
                let set = Planner.build(apps: [app], all: all, onEach: { _ in
                    found += 1
                    let count = found
                    DispatchQueue.main.async { self.progressLine = "正在扫描 \(app.name) · 已找到 \(count) 项" }
                })
                items.append(contentsOf: set.items)
                skipped.append(contentsOf: set.skipped)
            }
            let (_, rejected) = Planner.preflight(items, apps: chosen)
            let planned = items                 // 交给主队列前先取不可变副本：Swift 6 不允许并发闭包捕获可变变量
            let skippedRows = skipped
            DispatchQueue.main.async {
                self.plan = planned
                self.skipped = skippedRows
                self.rejected = rejected
                self.planBuilding = false
                self.progressLine = ""
                if planned.isEmpty { self.message = t("Nothing left to delete was found") }
            }
        }
    }

    var checkedPlan: [PlanItem] { plan.filter { $0.checked } }
    var checkedBytes: Int64 { checkedPlan.reduce(0) { $0 + $1.bytes } }
    var planByApp: [(AppItem, [PlanItem])] {
        selectedApps.compactMap { app in
            let rows = plan.filter { $0.appPath == app.path }
            return rows.isEmpty ? nil : (app, rows)
        }
    }

    /// 勾选状态变化（界面直接改 plan 里的值，这里只做通知与联动）。
    func togglePlan(_ item: PlanItem) {
        guard let index = plan.firstIndex(where: { $0.id == item.id }) else { return }
        plan[index].checked.toggle()
    }

    func runUninstall() {
        /* 权限没给全就不动刀：半吊子卸载（本体删了、容器留着）比不卸更烦。
           用户 2026-10-10：「卸不干净就等权限到了再说，而不是半吊子卸载」。 */
        guard Permissions.allGranted else {
            refreshPermissions()
            uninstallBlocked = true
            sheet = .permissions
            return
        }
        let items = checkedPlan
        let chosen = selectedApps
        resultIcons = Dictionary(uniqueKeysWithValues: chosen.compactMap { app in
            icons[app.path].map { (app.path, $0) }
        })
        let skipList = skipped
        sheet = .running
        progressLine = t("Preparing…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Remover.execute(items: items, skipped: skipList, apps: chosen) { line in
                DispatchQueue.main.async { self.progressLine = line }
            }
            DispatchQueue.main.async {
                self.outcome = result
                self.resultPulse = false
                self.sheet = .result
                self.plan = []
                self.skipped = []
                self.rejected = []
                self.confirmText = ""
                self.scan()
            }
        }
    }

    // MARK: - 杂项

    func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.trash))
    }

    func openLogFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.logDirectory))
    }

    func app(for path: String) -> AppItem? { apps.first { $0.path == path } }
}

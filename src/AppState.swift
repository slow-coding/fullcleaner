// 界面状态与流程：扫描应用 → 勾选 → 生成清单 → 确认 → 执行 → 结果。
// 状态与界面分开：界面只读 state，改数据只调这里的方法。

import Foundation
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var apps: [AppItem] = []
    @Published var query: String = ""
    @Published var selection: Set<String> = []          // 勾中的应用 path
    @Published var showSystem: Bool = false
    @Published var hovered: String?
    @Published var sortKey: SortKey = SortKey(rawValue: UserDefaults.standard.string(forKey: "sortKey") ?? "") ?? .size {
        didSet { UserDefaults.standard.set(sortKey.rawValue, forKey: "sortKey") }
    }
    @Published var scanning: Bool = true
    @Published var phase: String = "正在扫描已安装的应用…"
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
    @Published var lastScanFinished: Date? = nil
    @Published var message: String = ""

    enum Sheet: Identifiable {
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
        scan()
    }

    func scan() {
        stopFlag = StopFlag()
        scanning = true
        phase = "正在扫描已安装的应用…"
        residueCount = [:]
        selection = []
        scanningLine = ""
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
            for app in list {
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

    var visible: [AppItem] {
        var rows = apps
        if !showSystem { rows = rows.filter { !$0.protected } }
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !text.isEmpty { rows = rows.filter { $0.name.lowercased().contains(text) } }
        return SortKey.sorted(rows, by: sortKey)
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

    // MARK: - 清单

    /// 生成清单：找残留 + 量体积。这步可能慢（容器动辄几个 GB），所以放到后台。
    func buildPlan() {
        let chosen = selectedApps
        guard !chosen.isEmpty else { return }
        planBuilding = true
        sheet = .review
        progressLine = "正在找残留并量体积…"
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
                if planned.isEmpty { self.message = "没有找到可以删的东西" }
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
        let items = checkedPlan
        let chosen = selectedApps
        let skipList = skipped
        sheet = .running
        progressLine = "准备开始…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Remover.execute(items: items, skipped: skipList, apps: chosen) { line in
                DispatchQueue.main.async { self.progressLine = line }
            }
            DispatchQueue.main.async {
                self.outcome = result
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

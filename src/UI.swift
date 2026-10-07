// 界面：应用列表（多选）→「下一步」→ 深度扫描 → 卸载清单 → 执行 → 结果。
// 规矩：每行只留名字 / 路径 / 大小 / 徽标；机制解释进悬停提示；
// 拿不准的条目根本不进清单（判断归属是工具的事，不该问用户）。

import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var state: AppState

    // 表格列宽：一处定义，表头与数据行共用
    private enum Col {
        static let lead: CGFloat = 56        // 勾选框 + 图标
        static let size: CGFloat = 88
        static let opened: CGFloat = 108
        static let opens: CGFloat = 84
        static let residue: CGFloat = 72
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 520)
        .sheet(item: $state.sheet) { sheet in
            switch sheet {
            case .permissions: PermissionsSheet(state: state)
            case .review: ReviewSheet(state: state)
            case .running: RunningSheet(state: state)
            case .result: ResultSheet(state: state)
            }
        }
        .onAppear { state.start() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(t("%d apps installed · %@ total", state.apps.count, Format.size(state.apps.reduce(0) { $0 + $1.bytes })))
                .font(.system(size: 15, weight: .semibold))
            if state.scanning {
                ProgressView().controlSize(.small)
                Text(state.scanningLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                state.refreshPermissions()
                state.sheet = .permissions
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(state.permissionRows.allSatisfy { $0.status == .granted } ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(t("Permissions"))
                }
            }
            .controlSize(.small)
            .help(permissionHelp)
            Menu {
                ForEach(Lang.allCases) { lang in
                    Button(lang.label) { state.use(lang) }
                }
            } label: {
                Image(systemName: "globe")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(t("Language"))
            Button(t("Rescan")) { state.scan() }
                .controlSize(.small)
                .disabled(state.scanning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
            TextField(t("Search apps"), text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            Spacer()
            Toggle(t("Show system apps (%d)", state.systemCount), isOn: $state.showSystem)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help(t("System apps are protected by SIP — this tool does not uninstall them, it just shows them"))
            Button(t("Clear selection")) { state.clearSelection() }
                .controlSize(.small)
                .disabled(state.selection.isEmpty)
                .opacity(state.selection.isEmpty ? 0 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var list: some View {
        VStack(spacing: 0) {
            tableHeader
            Divider().opacity(0.5)
            // 用原生 List：底层是 NSTableView，滚动比 ScrollView+LazyVStack 顺，行还有复用
            List {
                ForEach(state.visible) { app in
                    row(app)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(rowBackground(app,
                                                        checked: state.selection.contains(app.path),
                                                        hovered: state.hovered == app.path))
                }
                if state.visible.isEmpty {
                    Text(state.scanning ? t("Scanning…") : t("No matching apps"))
                        .foregroundStyle(.secondary)
                        .padding(20)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: Col.lead, height: 1)
            headerCell(.nameAsc, width: nil, trailing: false)
            headerCell(.size, width: Col.size, trailing: true)
            headerCell(.lastOpened, width: Col.opened, trailing: true)
            headerCell(.openCount, width: Col.opens, trailing: true)
            Text(t("Leftovers"))
                .foregroundStyle(.secondary)
                .frame(width: Col.residue, alignment: .trailing)
                .help(t("Not sortable: this column is counted in the background"))
        }
        .font(.system(size: 10.5, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    /// 表头一格：点一下按这一列排序，再点一下换方向；当前排序列显示箭头。
    private func headerCell(_ key: SortKey, width: CGFloat?, trailing: Bool) -> some View {
        let active = state.sortKey == key
        let label = HStack(spacing: 3) {
            if trailing { Spacer(minLength: 0) }
            Text(key.label)
            if active {
                Image(systemName: state.sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            if !trailing { Spacer(minLength: 0) }
        }
        .foregroundStyle(active ? Color.primary : Color.secondary)

        let button = Button { state.sort(by: key) } label: {
            label.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t("Sort by “%@” — click again to reverse", key.label))

        return Group {
            if let width {
                button.frame(width: width)
            } else {
                button.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ app: AppItem) -> some View {
        let checked = state.selection.contains(app.path)
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { checked }, set: { _ in state.toggle(app) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(app.protected)
                Image(nsImage: state.icon(for: app))
                    .resizable().frame(width: 22, height: 22)
                    .opacity(app.protected ? 0.45 : 1)
            }
            .frame(width: Col.lead, alignment: .leading)

            HStack(spacing: 6) {
                Text(app.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(app.protected ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Text(app.displayVersion).font(.system(size: 10.5)).foregroundStyle(.secondary)
                if app.protected { badge(t("System"), color: .secondary) }
                if app.isMAS { badge("App Store", color: .blue) }
                if app.rootOwned && !app.protected { badge(t("Admin"), color: .orange) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(Format.size(app.bytes))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(app.protected ? Color.secondary : Color.primary)
                .frame(width: Col.size, alignment: .trailing)
            Text(Format.age(app.lastOpened))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: Col.opened, alignment: .trailing)
            Text(app.openCount.map(String.init) ?? "—")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: Col.opens, alignment: .trailing)
            Group {
                if let count = state.residueCount[app.path] {
                    Text(count > 0 ? "\(count)" : "—")
                        .foregroundStyle(count > 0 ? Color.orange : Color.secondary)
                } else {
                    Text("·").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .frame(width: Col.residue, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)                       // 行高钉死：选中/取消都不会让整页高度抖一下
        .contentShape(Rectangle())
        .onTapGesture { state.toggle(app) }
        .onHover { inside in
            if inside { state.hovered = app.path }
            else if state.hovered == app.path { state.hovered = nil }
        }
        .help(help(app))
    }

    private func help(_ app: AppItem) -> String {
        var lines = [app.bundleID]
        if let last = app.lastOpened { lines.append(t("Last opened %@", Format.date(last))) }
        if let count = app.openCount { lines.append(t("%d opens", count)) }
        return lines.joined(separator: " · ")
    }

    /// 行的底色：选中的用强调色；系统自带的压一层几乎看不见的灰，跟能卸的分开。
    private func rowBackground(_ app: AppItem, checked: Bool, hovered: Bool) -> Color {
        if checked { return Color.accentColor.opacity(0.12) }
        if hovered { return Color.primary.opacity(0.06) }
        return app.protected ? Color.primary.opacity(0.035) : Color.clear
    }

    private var permissionHelp: String {
        let missing = state.permissionRows.filter { $0.status != .granted }.map { $0.permission.title }
        return missing.isEmpty ? t("Permissions are all granted") : t("Missing: %@ (open to request)", missing.joined(separator: ", "))
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(state.selection.isEmpty ? " " : t("%d selected · %@", state.selectedApps.count, Format.size(state.selectedBytes)))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer()
            Button(t("Open log folder")) { state.openLogFolder() }
                .controlSize(.small)
            Button(t("Next")) { state.buildPlan() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(state.selection.isEmpty || state.planBuilding)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - 权限

struct PermissionsSheet: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Permissions")).font(.system(size: 15, weight: .semibold))
            Text(t("Only these are actually used. Accessibility and Input Monitoring are not needed and are never requested."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(state.permissionRows) { row in
                    rowView(row)
                    if row.id != state.permissionRows.last?.id { Divider().opacity(0.3) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))

            HStack(spacing: 10) {
                Spacer()
                Button(t("Check again")) { state.refreshPermissions() }
                Button(t("Done")) { state.sheet = nil }
            }
        }
        .padding(18)
        .frame(width: 580)
    }

    private func rowView(_ row: PermissionRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(row)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.permission.title).font(.system(size: 12.5, weight: .medium))
                    Text(row.status.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(row.status == .granted ? Color.green : Color.orange)
                    if row.checking {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text(t("Waiting for macOS…")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(row.permission.purpose)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if row.status != .granted {
                    Text(row.permission.settingsHint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if row.status != .granted {
                Button(t("Request")) { state.requestPermission(row.permission) }
                    .controlSize(.small)
                    .disabled(row.checking)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusIcon(_ row: PermissionRow) -> some View {
        switch row.status {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .unknown:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: - 深度扫描 + 卸载清单

struct ReviewSheet: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.planBuilding {
                scanning
            } else {
                header
                itemList
                if !state.rejected.isEmpty { rejectedList }
                footer
            }
        }
        .padding(18)
        .frame(width: 720, height: 620)
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(t("Deep-scanning leftovers")).font(.system(size: 14, weight: .semibold))
            }
            Text(state.progressLine)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var header: some View {
        Text(t("Uninstall %d apps · %d items · %@", state.selectedApps.count, state.checkedPlan.count, Format.size(state.checkedBytes)))
            .font(.system(size: 15, weight: .semibold))
    }

    private var itemList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(state.planByApp, id: \.0.path) { app, rows in
                    HStack(spacing: 8) {
                        Image(nsImage: state.icon(for: app))
                            .resizable().frame(width: 18, height: 18)
                        Text(app.name).font(.system(size: 12.5, weight: .semibold))
                        Text(t("%d/%d items · %@", rows.filter { $0.checked }.count, rows.count,
                                     Format.size(rows.filter { $0.checked }.reduce(0) { $0 + $1.bytes })))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    ForEach(rows) { item in
                        itemRow(item)
                        Divider().opacity(0.25)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }

    private func itemRow(_ item: PlanItem) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Toggle("", isOn: Binding(get: { item.checked }, set: { _ in state.togglePlan(item) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            Text(item.bytes > 0 ? Format.size(item.bytes) : "—")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 72, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    if let kind = item.kind {
                        badge(kind.label, color: .secondary).help(kind.explain)
                    } else {
                        badge(t("App bundle"), color: .accentColor)
                    }
                    if item.needsAdmin { badge(t("Admin"), color: .orange) }
                }
                Text(Format.short(item.path))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .help(item.why + (item.note.isEmpty ? "" : " \(item.note)"))
    }

    private var rejectedList: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t("%d blocked", state.rejected.count))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(state.rejected.enumerated()), id: \.offset) { _, rejection in
                        Text("\(rejection.reason) —— \(Format.short(rejection.path))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(CGFloat(state.rejected.count) * 15 + 6, 80))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !state.skipped.isEmpty {
                Text(t("%d items couldn't be attributed — skipped", state.skipped.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(state.skipped.prefix(8).map { Format.short($0.path) + "（\($0.reason)）" }.joined(separator: "\n"))
            }
            Spacer()
            Button(t("Cancel")) { state.sheet = nil }
            Button(t("Uninstall %d items", state.checkedPlan.count)) { state.runUninstall() }
                .buttonStyle(.borderedProminent)
                .disabled(state.checkedPlan.isEmpty)
        }
    }

    /// 行的底色：选中的用强调色；系统自带的压一层几乎看不见的灰，跟能卸的分开。
    private func rowBackground(_ app: AppItem, checked: Bool, hovered: Bool) -> Color {
        if checked { return Color.accentColor.opacity(0.12) }
        if hovered { return Color.primary.opacity(0.06) }
        return app.protected ? Color.primary.opacity(0.035) : Color.clear
    }

    private var permissionHelp: String {
        let missing = state.permissionRows.filter { $0.status != .granted }.map { $0.permission.title }
        return missing.isEmpty ? t("Permissions are all granted") : t("Missing: %@ (open to request)", missing.joined(separator: ", "))
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}

// MARK: - 执行中

struct RunningSheet: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(t("Uninstalling…")).font(.system(size: 14, weight: .semibold))
            }
            Text(state.progressLine).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(width: 520, height: 160)
    }
}

// MARK: - 结果

struct ResultSheet: View {
    @ObservedObject var state: AppState

    var body: some View {
        let outcome = state.outcome
        let removed = outcome?.totalRemoved ?? 0
        let bytes = outcome?.totalBytes ?? 0
        let failures = outcome?.allFailures ?? []

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.green.opacity(0.16)).frame(width: 52, height: 52)
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.green)
                }
                .scaleEffect(state.resultPulse ? 1 : 0.75)
                .opacity(state.resultPulse ? 1 : 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text(removed > 0 ? t("%d items removed", removed) : t("Nothing to remove"))
                        .font(.system(size: 19, weight: .semibold))
                    Text(bytes > 0 ? t("%@ went to the Trash — you can drag it back", Format.size(bytes)) : " ")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .opacity(state.resultPulse ? 1 : 0)

            if !failures.isEmpty {
                Text(t("%d items were left alone: %@", failures.count,
                       failures.prefix(2).map { $0.reason }.joined(separator: "; ")))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .help(failures.map { "\($0.reason) —— \(Format.short($0.path))" }.joined(separator: "\n"))
            }

            HStack(spacing: 8) {
                ForEach(outcome?.perApp ?? [], id: \.appName) { result in
                    if result.removedCount > 0 {
                        HStack(spacing: 6) {
                            Image(nsImage: state.app(for: result.appPath).map { state.icon(for: $0) }
                                  ?? NSWorkspace.shared.icon(forFile: "/Applications"))
                                .resizable().frame(width: 14, height: 14)
                            Text(result.appName).font(.system(size: 11.5))
                            Text(Format.size(result.removedBytes))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                    }
                }
                Spacer()
            }

            HStack {
                Button(t("Open Trash")) { state.openTrash() }.controlSize(.small)
                Button(t("Open log")) { state.openLogFolder() }.controlSize(.small)
                Spacer()
                Button(t("Done")) { state.sheet = nil }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            state.resultPulse = false
            withAnimation(.spring(response: 0.38, dampingFraction: 0.7)) { state.resultPulse = true }
        }
    }
}

// 判据层：哪些残留算这个应用的、哪些能删。
//
// 一条残留要进清单，必须拿得出证据（三选一）：
//   ① 路径名等于 bundle id，或它的前缀（帮助程序 / 子组件）；
//   ② 应用签名里声明的 App Group 共享容器（且没有别的已安装应用在用）；
//   ③ 按应用名匹配，但**在目录内容里读到了这个应用的 bundle id / 路径 / 可执行名**。
// 拿不出证据的（只有名字像）、还有别的应用在用的、会影响其他设备的（iCloud），
// 一律不进清单：不删、也不问用户 —— 判断归属是这个工具的事，不该丢给用户。
// 这些被跳过的条目会写进日志，数目在结果页报一行。

import Foundation

/// 已安装应用之间的共用关系：谁和谁声明了同一个容器。
struct SharedRegistry {
    private var groupOwners: [String: [(id: String, name: String)]] = [:]
    private var iCloudOwners: [String: [(id: String, name: String)]] = [:]
    private var ids: [String] = []

    init(apps: [AppItem]) {
        for app in apps {
            ids.append(app.bundleID.lowercased())
            let entry = (id: app.bundleID.lowercased(), name: app.name)
            for group in app.appGroups { groupOwners[group.lowercased(), default: []].append(entry) }
            for container in app.iCloudContainers { iCloudOwners[container.lowercased(), default: []].append(entry) }
        }
    }

    /// 除了这个应用，还有谁声明用这个目录。
    /// 应用自己声明的容器不算「别人也在用」（那是它自己的）。
    func claimants(of id: String, excluding app: AppItem) -> [String] {
        let key = id.lowercased()
        let own = app.bundleID.lowercased()
        var names: [String] = []
        for entry in (groupOwners[key] ?? []) + (iCloudOwners[key] ?? []) where entry.id != own {
            names.append(entry.name)
        }
        for other in ids where other != own {
            if key == other || key.hasPrefix(other + ".") || other.hasPrefix(key + ".") { names.append(other) }
        }
        return Array(Set(names)).sorted()
    }
}

/// 按应用名匹配到的目录，去内容里找证据：读到这个应用的 bundle id / 路径 / 可执行名才算数。
enum Verifier {
    /// 返回读到的证据（没有就是 nil）。
    static func evidence(bundleID: String, appPath: String, executable: String, in path: String) -> String? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let needles = [bundleID.lowercased(),
                       appPath.lowercased(),
                       (executable.isEmpty ? nil : executable.lowercased())].compactMap { $0 }
        if !isDirectory.boolValue {
            return fileEvidence(needles, at: path).map { "文件里写到了 \($0)" }
        }

        var visited = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = manager.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys,
                                                  errorHandler: { _, _ in true }) else { return nil }
        for case let child as URL in enumerator {
            visited += 1
            if visited > 400 { break }
            let name = child.lastPathComponent.lowercased()
            if let hit = needles.first(where: { name.contains($0) }) { return t("a file named after %@", hit) }
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, (values.fileSize ?? 0) < 512_000 else { continue }
            if let hit = fileEvidence(needles, at: child.path) { return t("found “%@” inside", hit) }
        }
        return nil
    }

    private static func fileEvidence(_ needles: [String], at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 384_000)
        guard !data.isEmpty else { return nil }
        for encoding in [String.Encoding.utf8, .isoLatin1] {
            guard let text = String(data: data, encoding: encoding)?.lowercased() else { continue }
            if let hit = needles.first(where: { text.contains($0) }) { return hit }
        }
        return nil
    }
}

/// 不进清单的条目，只写日志与结果页的一行统计。
struct Skipped {
    var path: String
    var appName: String
    var reason: String
}

struct PlannedSet {
    var items: [PlanItem] = []      // 有证据的：进清单、默认删
    var skipped: [Skipped] = []     // 证据不足或不能动的：不展示、不删
}

enum Planner {

    static func build(apps: [AppItem], all: [AppItem], stop: StopFlag? = nil,
                      onEach: ((PlanItem) -> Void)? = nil) -> PlannedSet {
        let registry = SharedRegistry(apps: all)
        var set = PlannedSet()
        for app in apps {
            if stop?.stopped == true { break }

            var bundle = PlanItem(appPath: app.path, appName: app.name, path: app.path, bytes: app.bytes,
                                  kind: nil, match: nil, needsAdmin: app.rootOwned, checked: true)
            bundle.modified = app.modified
            if app.protected {
                // 系统自带 / Apple 应用不能被卸载：连残留都不去扫。
                // 扫它们没有任何用处，还会白碰 Music、Photos 这类系统应用的路径（会招来系统的媒体库弹窗）。
                set.skipped.append(Skipped(path: app.path, appName: app.name, reason: t("System app or Apple app")))
                continue
            }
            set.items.append(bundle)
            onEach?(bundle)

            for hit in ResidueScanner.residues(for: app, stop: stop) {
                // 共享容器：别人也在用 → 跳过（不问用户，也不删）
                if hit.kind == .groupContainer {
                    let others = registry.claimants(of: (hit.path as NSString).lastPathComponent, excluding: app)
                    if !others.isEmpty {
                        set.skipped.append(Skipped(path: hit.path, appName: app.name,
                                                   reason: "还有别的应用在用（\(others.joined(separator: "、"))）"))
                        continue
                    }
                }
                // iCloud 数据：删了会影响其他设备 → 跳过
                if hit.kind == .iCloudContainer {
                    set.skipped.append(Skipped(path: hit.path, appName: app.name, reason: t("iCloud data — deleting it would affect your other devices")))
                    continue
                }
                // 按应用名匹配的：必须读到证据才算它的
                var note = hit.note
                if hit.how == .appName {
                    guard let evidence = Verifier.evidence(bundleID: app.bundleID, appPath: app.path,
                                                           executable: app.executableName, in: hit.path) else {
                        set.skipped.append(Skipped(path: hit.path, appName: app.name, reason: t("Name looks similar, no evidence found")))
                        continue
                    }
                    note += " " + t("Evidence: %@.", evidence)
                }

                let item = PlanItem(appPath: app.path, appName: app.name, path: hit.path, bytes: hit.bytes,
                                    kind: hit.kind, match: hit.how, note: note,
                                    needsAdmin: hit.kind.needsAdmin || isSystemPath(hit.path),
                                    checked: true, modified: hit.modified)
                set.items.append(item)
                onEach?(item)
            }
        }
        return set
    }

    static func isSystemPath(_ path: String) -> Bool {
        let systemLibrary = Paths.system("/Library/")
        return path.hasPrefix(systemLibrary) || path.hasPrefix(Paths.system("/Applications"))
    }

    // MARK: - 闸门（删之前的最后一道）

    static func preflight(_ items: [PlanItem], apps: [AppItem]) -> (ok: [PlanItem], rejected: [Rejection]) {
        let appByPath = Dictionary(uniqueKeysWithValues: apps.map { ($0.path, $0) })
        var ok: [PlanItem] = []
        var rejected: [Rejection] = []

        for item in items where item.checked {
            let app = appByPath[item.appPath]
            if let reason = reject(item, app: app) {
                rejected.append(Rejection(path: item.path, appName: item.appName, reason: reason.reason, gate: reason.gate))
            } else {
                ok.append(item)
            }
        }

        // 同一批里父子目录都在：只留父目录
        let sorted = ok.sorted { $0.path.count < $1.path.count }
        var kept: [PlanItem] = []
        for item in sorted {
            if kept.contains(where: { $0.path == item.path }) { continue }
            if kept.contains(where: { item.path.hasPrefix($0.path + "/") && $0.appPath == item.appPath }) { continue }
            kept.append(item)
        }
        for item in ok where !kept.contains(where: { $0.id == item.id }) {
            rejected.append(Rejection(path: item.path, appName: item.appName,
                                      reason: t("Its parent folder is being deleted too — the parent is enough"), gate: t("No collateral damage")))
        }
        ok = kept

        // 两个应用都勾了同一个路径：谁都不删
        var seen: [String: String] = [:]
        for item in ok {
            if let first = seen[item.path], first != item.appPath {
                rejected.append(Rejection(path: item.path, appName: item.appName,
                                          reason: t("%@ also selected this one; when two apps claim a path, neither is deleted", first), gate: t("No collateral damage")))
            } else {
                seen[item.path] = item.appPath
            }
        }
        ok = ok.filter { item in !rejected.contains { $0.path == item.path && $0.gate == t("No collateral damage") } }
        return (ok, rejected)
    }

    /// 单条的硬检查。
    static func reject(_ item: PlanItem, app: AppItem?) -> (gate: String, reason: String)? {
        let manager = FileManager.default
        let path = item.path

        if let app, app.protected { return (t("Protected paths"), t("%@ is a system or Apple app", app.name)) }
        if !item.sharedWith.isEmpty {
            return (t("No collateral damage"), t("Other apps still use it (%@) — deleting it would break them", item.sharedWith.joined(separator: ", ")))
        }
        guard path.hasPrefix("/") else { return (t("Path shape"), t("Not an absolute path")) }
        guard !path.contains("/../") else { return (t("Path shape"), t("Path contains .. — not deleted")) }
        guard manager.fileExists(atPath: path) else { return (t("Path shape"), t("Path does not exist any more")) }

        // 符号链接一律不删：它可能是绕开保护名单的跳板
        let attributes = try? manager.attributesOfItem(atPath: path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            return (t("Path shape"), t("This is a symlink — not deleted"))
        }
        // 解析真实路径后仍要在允许的目录里；应用本体走它自己的白名单
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let inDeletionRoots = Paths.deletionRoots.contains { real == $0 || real.hasPrefix($0 + "/") }
        let inAppDirectories = item.isAppBundle && Paths.appDirectories.contains { path.hasPrefix($0 + "/") }
        guard inDeletionRoots || inAppDirectories else {
            return (t("Protected paths"), t("Not inside the directories this tool may delete from"))
        }
        if Paths.neverTouch.contains(where: { path == $0 }) {
            return (t("Protected paths"), t("This is a protected path itself"))
        }
        if path.hasPrefix(Paths.library + "/Preferences/com.apple.") {
            return (t("Protected paths"), t("macOS's own preference file — not touched"))
        }

        if item.isAppBundle {
            guard Paths.appDirectories.contains(where: { path.hasPrefix($0 + "/") }) else {
                return (t("Protected paths"), t("This app is not in a standard app folder (/Applications or ~/Applications)"))
            }
            guard !path.hasPrefix(Paths.system("/System/")) else {
                return (t("Protected paths"), t("Built-in system app, protected by SIP"))
            }
        }

        if let app {
            let itemVolume = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
            let appVolume = (try? URL(fileURLWithPath: app.path).resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
            if let itemVolume, let appVolume, String(describing: itemVolume) != String(describing: appVolume) {
                return (t("Same volume"), t("The app lives on another disk; cross-volume items are not touched"))
            }
        }
        return nil
    }
}

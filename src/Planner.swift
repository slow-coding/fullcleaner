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
            if let hit = needles.first(where: { name.contains($0) }) { return "目录里有以 \(hit) 命名的文件" }
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, (values.fileSize ?? 0) < 512_000 else { continue }
            if let hit = fileEvidence(needles, at: child.path) { return "文件里写到了 \(hit)" }
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
                set.skipped.append(Skipped(path: app.path, appName: app.name, reason: "系统自带或 Apple 的应用"))
            } else {
                set.items.append(bundle)
                onEach?(bundle)
            }

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
                    set.skipped.append(Skipped(path: hit.path, appName: app.name, reason: "iCloud 数据，删了其他设备也会少"))
                    continue
                }
                // 按应用名匹配的：必须读到证据才算它的
                var note = hit.note
                if hit.how == .appName {
                    guard let evidence = Verifier.evidence(bundleID: app.bundleID, appPath: app.path,
                                                           executable: app.executableName, in: hit.path) else {
                        set.skipped.append(Skipped(path: hit.path, appName: app.name, reason: "只有名字像，没有证据"))
                        continue
                    }
                    note += " 判据：\(evidence)。"
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
                                      reason: "它的上级目录这次也要删，删上级就够了", gate: "不误伤"))
        }
        ok = kept

        // 两个应用都勾了同一个路径：谁都不删
        var seen: [String: String] = [:]
        for item in ok {
            if let first = seen[item.path], first != item.appPath {
                rejected.append(Rejection(path: item.path, appName: item.appName,
                                          reason: "\(first) 那边也勾了这一条，两边都想删的目录本工具不动", gate: "不误伤"))
            } else {
                seen[item.path] = item.appPath
            }
        }
        ok = ok.filter { item in !rejected.contains { $0.path == item.path && $0.gate == "不误伤" } }
        return (ok, rejected)
    }

    /// 单条的硬检查。
    static func reject(_ item: PlanItem, app: AppItem?) -> (gate: String, reason: String)? {
        let manager = FileManager.default
        let path = item.path

        if let app, app.protected { return ("保护名单", "\(app.name) 是系统自带或 Apple 的应用") }
        if !item.sharedWith.isEmpty {
            return ("不误伤", "还有别的应用在用它（\(item.sharedWith.joined(separator: "、"))），删了它们会出问题")
        }
        guard path.hasPrefix("/") else { return ("路径形态", "不是绝对路径") }
        guard !path.contains("/../") else { return ("路径形态", "路径里有 ..，不删") }
        guard manager.fileExists(atPath: path) else { return ("路径形态", "路径已不存在") }

        // 符号链接一律不删：它可能是绕开保护名单的跳板
        let attributes = try? manager.attributesOfItem(atPath: path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            return ("路径形态", "这是符号链接，不删")
        }
        // 解析真实路径后仍要在允许的目录里；应用本体走它自己的白名单
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let inDeletionRoots = Paths.deletionRoots.contains { real == $0 || real.hasPrefix($0 + "/") }
        let inAppDirectories = item.isAppBundle && Paths.appDirectories.contains { path.hasPrefix($0 + "/") }
        guard inDeletionRoots || inAppDirectories else {
            return ("保护名单", "不在本工具允许删除的目录里")
        }
        if Paths.neverTouch.contains(where: { path == $0 }) {
            return ("保护名单", "这是受保护的目录本身")
        }
        if path.hasPrefix(Paths.library + "/Preferences/com.apple.") {
            return ("保护名单", "系统自己的偏好设置，不动")
        }

        if item.isAppBundle {
            guard Paths.appDirectories.contains(where: { path.hasPrefix($0 + "/") }) else {
                return ("保护名单", "这个应用不在标准应用目录（/Applications 或 ~/Applications）里，本工具不动它")
            }
            guard !path.hasPrefix(Paths.system("/System/")) else {
                return ("保护名单", "系统自带应用受 SIP 保护")
            }
        }

        if let app {
            let itemVolume = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
            let appVolume = (try? URL(fileURLWithPath: app.path).resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
            if let itemVolume, let appVolume, String(describing: itemVolume) != String(describing: appVolume) {
                return ("同一磁盘", "应用不在同一块磁盘上，跨盘的东西不删")
            }
        }
        return nil
    }
}

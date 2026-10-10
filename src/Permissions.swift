// 权限：这个工具真正需要的那**两项**，以及每项的当前状态与获取路径。
// 为什么只剩两项（2026-10-10 整理：用户「权限获取感觉乱七八糟的」）：
//   · 「文件与文件夹」（音乐 / 影片 / 图片 / 文稿 / iCloud Drive）不是独立的一项 —— 它的探针与状态
//     完全等同于完全磁盘访问，单列一行等于同一件事说两遍。那一行的信息并进这一项的悬停说明。
//   · 辅助功能、输入监控不申请：本工具不模拟按键、不读键盘，列出来只会误导。
// 界面只放 purpose 那一句；help 进悬停（用户 2026-10-07 的老毛病：界面里不要堆解释文字）。

import Foundation
import AppKit

enum Permission: String, CaseIterable, Identifiable {
    case fullDiskAccess
    case appManagement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullDiskAccess: return t("Full Disk Access")
        case .appManagement: return t("App Management")
        }
    }

    /// 面板上那一行的一句话（界面只放这一句）。
    var purpose: String {
        switch self {
        case .fullDiskAccess:
            return t("Read inside other apps' containers to match leftovers to an app and measure their sizes.")
        case .appManagement:
            return t("Move another app's bundle to the Trash (macOS 13 and later require it).")
        }
    }

    /// 悬停里的完整说明：为什么需要、覆盖什么、要不要单独授权。
    var help: String {
        switch self {
        case .fullDiskAccess:
            return t("Read inside other apps' containers — that is how a folder named after an app is verified to belong to it, and how leftover sizes are measured. Without it macOS asks repeatedly, or reads come back incomplete.")
                + "\n" + t("This one switch also covers Music / Movies / Pictures / Documents / iCloud Drive; without it those places are skipped entirely instead of prompting.")
        case .appManagement:
            return t("Move another app's bundle to the Trash. Since macOS 13, modifying a bundle you do not own requires it.")
        }
    }

    /// 状态读不出来时行内要写清为什么（只有 App 管理会走到这里）。
    var unknownHint: String? {
        self == .appManagement ? t("Needs Full Disk Access first — without it this row cannot be read.") : nil
    }

    /// 系统设置里对应的面板。
    var settingsURL: String {
        switch self {
        case .fullDiskAccess: return "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .appManagement: return "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"
        }
    }

    var settingsHint: String {
        switch self {
        case .fullDiskAccess:
            return t("System Settings → Privacy & Security → Full Disk Access → switch FullCleaner on")
        case .appManagement: return t("System Settings → Privacy & Security → App Management → switch FullCleaner on")
        }
    }
}

enum PermissionStatus {
    case granted        // 有权限：界面上一个绿色对号
    case missing        // 没权限：界面上给一个「去申请」
    case unknown        // 检测不了（例如还没给完全磁盘访问，读不到权限数据库）

    var label: String {
        switch self {
        case .granted: return t("Granted")
        case .missing: return t("Not granted")
        case .unknown: return t("Can't tell yet")
        }
    }
}

/// 界面上一行：权限 + 当前状态。
struct PermissionRow: Identifiable {
    let permission: Permission
    var status: PermissionStatus
    var checking: Bool = false          // 点过「去申请」之后，正在等系统放行
    var id: String { permission.rawValue }
}

enum Permissions {

    /// 探测一个权限的当前状态。只读探测，不做任何修改。
    static func status(_ permission: Permission) -> PermissionStatus {
        switch permission {
        case .fullDiskAccess:
            return fullDiskAccessState()
        case .appManagement:
            // 权限库本身受完全磁盘访问保护；读不到就只能说不确定（行内会写清为什么）。
            guard fullDiskAccessState() == .granted, let database = userTCCDatabase() else { return .unknown }
            switch authValue(database: database, service: "kTCCServiceAppManagement") {
            case 2: return .granted
            case 0: return .missing
            default: return .missing      // 数据库里没有记录 = 还没申请过
            }
        }
    }

    static func all() -> [PermissionRow] {
        Permission.allCases.map { PermissionRow(permission: $0, status: status($0)) }
    }

    static var allGranted: Bool { all().allSatisfy { $0.status == .granted } }

    /// 扫描时用：没有完全磁盘访问就不去碰会触发系统弹窗的位置。
    /// 自检里用 FULLCLEANER_FAKE_FDA=1 模拟t("Granted")，好把两种分支都验到。
    static var fullDiskAccessGranted: Bool {
        if ProcessInfo.processInfo.environment["FULLCLEANER_FAKE_FDA"] == "1" { return true }
        return fullDiskAccessState() == .granted
    }

    /// 还差哪几项（主界面上提示用）。
    static var missingTitles: [String] {
        all().filter { $0.status != .granted }.map { $0.permission.title }
    }

    /// 打开系统设置里对应的那一页（用户在那里勾选本应用）。
    static func openSettings(for permission: Permission) {
        guard let url = URL(string: permission.settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 打开设置后，系统的权限判定有几秒延迟；这段时间内重复探测。
    /// 为什么只等 20 秒（原来是 60）：拨开关 + 回来通常十来秒就够；等太久面板一直挂着转圈，
    /// 反而让人以为卡住了。等不到由界面给「重启 FullCleaner」的下一步（TCC 按进程缓存）。
    static func waitForGrant(_ permission: Permission, seconds: TimeInterval = 20) async -> PermissionStatus {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if status(permission) == .granted { return .granted }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        return status(permission)
    }

    // MARK: - 重启（权限生效的下一步）

    /// 能不能重启自己：只有 .app 形态（有 bundle）行；命令行直接跑二进制、自检里都不行。
    static var canRelaunch: Bool {
        !Sandbox.isSelfTest
            && Bundle.main.bundleURL.pathExtension == "app"
            && FileManager.default.isExecutableFile(atPath: Bundle.main.executableURL?.path ?? "")
    }

    /// 重启自己：macOS 的权限判定按进程缓存，开关拨上后常常要重启应用才生效 ——
    /// 面板上那颗「重启 FullCleaner」就走这里（`open -n` 拉起新实例，旧的自己退）。
    @discardableResult
    static func relaunch() -> Bool {
        guard canRelaunch else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        guard (try? process.run()) != nil else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NSApp.terminate(nil) }
        return true
    }

    // MARK: - 探测细节

    /// 完全磁盘访问的探针表：**任一条读得到 → 有权限；全读不到但至少有一条在 → 没权限；
    /// 一条都不在 → 判不了**。
    ///
    /// 为什么要一串而不是一个文件（2026-10-10，macOS 27 实测：用户报「权限都开了还显示未授权」）：
    /// 用户权限库在 macOS 27 从 `~/Library/Application Support/com.apple.TCC/TCC.db` 挪进了
    /// `/private/var/containers/Data/ProtectedSystem/<UUID>/Data/…` —— 旧路径直接不存在，读它
    /// 一律 ENOENT，只看旧路径就会把「已经授权」一律报成没授权。这台机器上 `head` 过旧路径：
    /// No such file or directory；而下面这几条在没授权时都是「Operation not permitted」。
    static let fullDiskAccessProbes = [
        Paths.home + "/Library/Application Support/com.apple.TCC/TCC.db",   // macOS ≤ 26 的用户权限库
        "/private/var/containers/Data/ProtectedSystem",                     // macOS 27+：保护容器（列目录就要权限）
        Paths.home + "/Library/Messages/chat.db",                           // 信息库
        Paths.home + "/Library/Safari/Bookmarks.plist",                     // Safari 数据
        Paths.home + "/Library/Mail",                                       // 邮件数据
    ]

    /// 真探针（不看自检的 FULLCLEANER_FAKE_FDA）：面板与状态判定走它。
    static func fullDiskAccessState() -> PermissionStatus {
        var sawDenied = false
        for path in fullDiskAccessProbes {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if canRead(path, isDirectory: isDirectory.boolValue) { return .granted }
            sawDenied = true
        }
        return sawDenied ? .missing : .unknown
    }

    /// 读一小段 / 列一眼目录：能读就是有权限（不修改任何东西）。
    private static func canRead(_ path: String, isDirectory: Bool) -> Bool {
        if isDirectory {
            return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16)) != nil
    }

    /// 用户权限库的位置：macOS 27 起搬进了 ProtectedSystem（旧路径不存在，所以两个位置都找）。
    static func userTCCDatabase() -> String? {
        let legacy = Paths.home + "/Library/Application Support/com.apple.TCC/TCC.db"
        if FileManager.default.fileExists(atPath: legacy) { return legacy }
        let root = "/private/var/containers/Data/ProtectedSystem"
        guard let containers = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        for container in containers.sorted() {
            let candidate = root + "/" + container + "/Data/Library/Application Support/com.apple.TCC/TCC.db"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// 从权限库里查一项服务的授权值：2 = 允许，0 = 拒绝，没有记录 = nil。
    private static func authValue(database: String, service: String) -> Int? {
        guard FileManager.default.fileExists(atPath: database) else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "local.fullcleaner"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database,
                             "select auth_value from access where service='\(service)' and client='\(bundleID)' limit 1;"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int(text)
    }
}

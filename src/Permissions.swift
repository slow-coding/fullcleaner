// 权限：这个工具真正需要的系统权限，以及每项的当前状态。
// 只需要两项——完全磁盘访问（读别的应用的容器内容）与 App 管理（改动别的应用本体）。
// 辅助功能、输入监控这类不申请：本工具不模拟按键、不读键盘，列出来只会误导。

import Foundation
import AppKit

enum Permission: String, CaseIterable, Identifiable {
    case fullDiskAccess
    case filesAndFolders
    case appManagement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullDiskAccess: return t("Full Disk Access")
        case .filesAndFolders: return t("Files and Folders (Music / Movies / Pictures / Documents / iCloud Drive)")
        case .appManagement: return t("App Management")
        }
    }

    var purpose: String {
        switch self {
        case .fullDiskAccess:
            return t("Read inside other apps' containers — that is how a folder named after an app is verified to belong to it, and how leftover sizes are measured. Without it macOS asks repeatedly, or reads come back incomplete.")
        case .filesAndFolders:
            return t("Those locations make macOS prompt once. Full Disk Access covers them all; without it this app skips them entirely instead of interrupting you.")
        case .appManagement:
            return t("Move another app's bundle to the Trash. Since macOS 13, modifying a bundle you do not own requires it.")
        }
    }

    /// 系统设置里对应的面板。
    var settingsURL: String {
        switch self {
        case .fullDiskAccess, .filesAndFolders: return "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .appManagement: return "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"
        }
    }

    var settingsHint: String {
        switch self {
        case .fullDiskAccess, .filesAndFolders:
            return t("System Settings → Privacy & Security → Full Disk Access → switch FullCleaner on (this one covers all of the above)")
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
            return canReadTCCDatabase() ? .granted : .missing
        case .filesAndFolders:
            return canReadTCCDatabase() ? .granted : .missing   // 完全磁盘访问覆盖它
        case .appManagement:
            // 权限数据库本身受完全磁盘访问保护；读不到就只能说不确定。
            guard canReadTCCDatabase() else { return .unknown }
            switch authValue(service: "kTCCServiceAppManagement") {
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
        return canReadTCCDatabase()
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
    static func waitForGrant(_ permission: Permission, seconds: TimeInterval = 60) async -> PermissionStatus {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if status(permission) == .granted { return .granted }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        return status(permission)
    }

    // MARK: - 探测细节

    /// 用户权限数据库只有拿到完全磁盘访问才能读 —— 用它当探针。
    static func canReadTCCDatabase() -> Bool {
        readDatabase() != nil
    }

    private static func readDatabase() -> Data? {
        let path = Paths.home + "/Library/Application Support/com.apple.TCC/TCC.db"
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return handle.readData(ofLength: 64)
    }

    /// 从权限数据库里查一项服务的授权值：2 = 允许，0 = 拒绝，没有记录 = nil。
    private static func authValue(service: String) -> Int? {
        let path = Paths.home + "/Library/Application Support/com.apple.TCC/TCC.db"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "local.fullcleaner"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path,
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

// 数据模型与格式化。只放类型定义与纯函数，不碰文件系统。

import Foundation

/// 一个已安装的应用。
/// 列表排序方式。语义写在 sorted(_:) 里，自检会逐条验。
enum SortKey: String, CaseIterable, Identifiable {
    case size            // 占地方在前
    case lastOpened      // 最近打开的在前
    case openCount       // 打开次数多的在前
    case nameAsc         // 名称 A→Z

    var id: String { rawValue }

    var label: String {
        switch self {
        case .size: return t("Size")
        case .lastOpened: return t("Last opened")
        case .openCount: return t("Opens")
        case .nameAsc: return t("App")
        }
    }

    /// 表头第一次点这个列时的方向：数字列从大到小，名称从 A 到 Z。
    var defaultAscending: Bool { self == .nameAsc }

    /// 纯函数：没有时间或次数的（—）永远排在后面，不参与方向翻转。
    /// ascending = true 表示这个列顺着排（名称 A→Z、数字从小到大）。
    static func sorted(_ apps: [AppItem], by key: SortKey, ascending: Bool) -> [AppItem] {
        func nameOrder(_ a: AppItem, _ b: AppItem) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        switch key {
        case .size:
            return apps.sorted { ascending ? $0.bytes < $1.bytes : $0.bytes > $1.bytes }
        case .lastOpened:
            return apps.sorted { a, b in
                switch (a.lastOpened, b.lastOpened) {
                case let (x?, y?): return ascending ? x < y : x > y
                case (nil, _?): return false      // 没记录的永远在后
                case (_?, nil): return true
                case (nil, nil): return nameOrder(a, b)
                }
            }
        case .openCount:
            return apps.sorted { a, b in
                switch (a.openCount, b.openCount) {
                case let (x?, y?): return ascending ? x < y : x > y
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return nameOrder(a, b)
                }
            }
        case .nameAsc:
            return apps.sorted { ascending ? nameOrder($0, $1) : nameOrder($1, $0) }
        }
    }
}

struct AppItem: Identifiable, Hashable {
    var path: String                  // /Applications/Foo.app
    var bundleID: String
    var name: String                  // 界面上的名字
    var version: String
    var bytes: Int64
    var isSystem: Bool                // 在 /System/Applications 下，受 SIP 保护
    var isMAS: Bool                   // 带 App Store 收据
    var rootOwned: Bool               // 目录属于 root，删除需要管理员
    var executableName: String
    var nestedBundleIDs: [String]     // 包内的登录项 / 帮助程序 / 插件，各有自己的权限条目
    var loginItemLabels: [String]     // 包内 LoginItems / LaunchAgents 的 label
    var appGroups: [String]           // 签名里声明的 App Group
    var iCloudContainers: [String]    // 签名里声明的 iCloud 容器
    var modified: Date?
    var lastOpened: Date? = nil       // 上次打开（可执行文件的访问时间）
    var openCount: Int? = nil         // 打开次数（Spotlight 的使用计数）
    var iconPath: String = ""         // 取图标用的路径（演示数据里指向系统应用）

    var id: String { path }
    var icon: String { iconPath.isEmpty ? path : iconPath }
    /// 系统自带、或者 Apple 自己的应用，一律不动。
    var protected: Bool { isSystem || bundleID.hasPrefix("com.apple.") || path.hasPrefix("/System/") }
    var displayVersion: String { version.isEmpty ? "—" : version }
}

/// 残留属于哪一类。界面上按类分组，并且每类都写清"这是什么"。
enum ResidueKind: String, CaseIterable, Codable {
    case container            // 沙盒容器：应用自己的数据目录
    case groupContainer       // 多个应用共享的容器
    case appScripts           // 沙盒应用的脚本目录
    case preferences          // 偏好设置 plist
    case savedState           // 窗口状态
    case cache                // 缓存
    case httpStorage          // 网络缓存与 cookie
    case webkit               // 内嵌网页的数据
    case applicationSupport   // 应用支持目录（插件、数据库、配置）
    case crashReporter        // 崩溃报告（旧路径）
    case logs                 // 日志
    case launchAgent          // 开机自启 / 常驻服务
    case systemLibrary        // /Library 下的系统级残留（需要管理员）
    case helperTool           // 特权帮助工具（需要管理员）
    case packageReceipt       // 安装包收据（pkgutil）
    case iCloudContainer      // iCloud Drive 里的数据（其他设备共用）

    var label: String {
        switch self {
        case .container: return t("Container")
        case .groupContainer: return t("Group container")
        case .appScripts: return t("Scripts folder")
        case .preferences: return t("Preferences")
        case .savedState: return t("Window state")
        case .cache: return t("Cache")
        case .httpStorage: return t("Web storage")
        case .webkit: return t("WebKit data")
        case .applicationSupport: return t("Application support")
        case .crashReporter: return t("Crash reporter")
        case .logs: return t("Logs")
        case .launchAgent: return t("Launch agent")
        case .systemLibrary: return t("System-level leftover")
        case .helperTool: return t("Helper tool")
        case .packageReceipt: return t("Package receipt")
        case .iCloudContainer: return t("iCloud data")
        }
    }

    var explain: String {
        switch self {
        case .container: return t("The app's own sandbox container: chat history, databases, downloaded assets.")
        case .groupContainer: return t("Shared between apps from the same developer — check whether another app still uses it.")
        case .appScripts: return t("Where a sandboxed app keeps its scripts; usually empty.")
        case .preferences: return t("Preferences. Delete them and the app starts from defaults.")
        case .savedState: return t("Window position and expansion state.")
        case .cache: return t("Cache the app built up; it will recreate it.")
        case .httpStorage: return t("HTTP cache and cookies. Apps that need a login may ask again.")
        case .webkit: return t("Local data of web views inside the app.")
        case .applicationSupport: return t("Plugins, templates and local databases often live here.")
        case .crashReporter: return t("Old crash reports — they only take up space.")
        case .logs: return t("Logs written by the app.")
        case .launchAgent: return t("Launch-at-login or background service. It has to go with the app, otherwise it keeps trying to start something that no longer exists.")
        case .systemLibrary: return t("Files installed under /Library; removing them needs an administrator.")
        case .helperTool: return t("A privileged helper installed for the app; removing it needs an administrator.")
        case .packageReceipt: return t("macOS remembers the app was installed from a package. Harmless to keep, but a clean uninstall forgets it.")
        case .iCloudContainer: return t("Data this app keeps in iCloud Drive. Deleting it affects your other devices, not just this Mac.")
        }
    }

    /// 删之前要提醒的那一类。
    var isDataLoss: Bool {
        switch self {
        case .iCloudContainer, .container, .groupContainer, .applicationSupport: return true
        default: return false
        }
    }

    /// 需要管理员密码。
    var needsAdmin: Bool {
        switch self {
        case .systemLibrary, .helperTool, .packageReceipt: return true
        default: return false
        }
    }

    /// 不能按名字瞎猜的那几类，默认不勾（用户要自己去核）。
    var riskyWhenMatchedByName: Bool {
        switch self {
        case .container, .groupContainer, .applicationSupport, .systemLibrary, .iCloudContainer: return true
        default: return false
        }
    }
}

/// 这条是怎么匹配上的。界面上一眼能看出"凭什么说它属于这个应用"。
enum MatchHow: String, Codable {
    case exactID            // 路径里的名字等于 bundle id
    case idPrefix           // 以 bundle id 开头（.helper / .cli 这类）
    case appGroup           // 签名里声明的 App Group
    case appName            // 按应用名匹配（同名目录），要人多看一眼
    case loginItem          // 包内自启项的 label
    case packageReceipt     // 安装包收据 id

    var label: String {
        switch self {
        case .exactID: return "bundle id"
        case .idPrefix: return t("bundle id prefix")
        case .appGroup: return "App Group"
        case .appName: return t("app name")
        case .loginItem: return t("login item")
        case .packageReceipt: return t("package receipt")
        }
    }

    var explain: String {
        switch self {
        case .exactID: return t("The folder name is exactly the app's bundle id.")
        case .idPrefix: return t("The folder name starts with the bundle id — a helper or sub-component.")
        case .appGroup: return t("A shared container id declared in the app's own signature.")
        case .appName: return t("Matched by app name, and the app's bundle id was read inside the folder.")
        case .loginItem: return t("A launch-item label declared inside the app bundle.")
        case .packageReceipt: return t("A receipt id from macOS's installer records.")
        }
    }
}

/// 清单里的一行：要么是应用本体，要么是它的残留。
struct PlanItem: Identifiable, Hashable {
    var appPath: String               // 属于哪个应用（AppItem.path）
    var appName: String
    var path: String
    var bytes: Int64
    var kind: ResidueKind?            // nil = 应用本体
    var match: MatchHow?              // nil = 应用本体
    var note: String = ""
    var needsAdmin: Bool = false
    var checked: Bool = true
    var modified: Date?
    var sharedWith: [String] = []     // 还有哪些已安装应用也声明用这个目录

    var id: String { appPath + "|" + path }
    var isAppBundle: Bool { kind == nil }
    var label: String { isAppBundle ? appName : (path as NSString).lastPathComponent }
    /// 用户能看懂的一行说明。
    var why: String {
        if isAppBundle { return t("App bundle (%@)", appPath) }
        guard let kind, let match else { return "" }
        return "\(kind.label)：\(match.explain)"
    }
}

/// 闸门拦下的东西。
struct Rejection {
    let path: String
    let appName: String
    let reason: String
    let gate: String
}

struct Gate {
    let name: String
    let detail: String
}

enum Gates {
    static let all: [Gate] = [
        .init(name: t("Protected paths"), detail: t("System paths, Apple’s apps, iCloud container roots and the tool’s own logs are never touched.")),
        .init(name: t("Path shape"), detail: t("Must exist, must not be a symlink, must stay inside an allow-list after resolving links, and must not be too shallow.")),
        .init(name: t("Same volume"), detail: t("Only the disk the app lives on; other disks and network volumes are left alone.")),
        .init(name: t("App already quit"), detail: t("The app and its helpers must be gone first; if they will not quit, nothing is removed.")),
        .init(name: t("No collateral damage"), detail: t("A parent and its child in the same batch keeps only the parent; a container two apps share is never removed.")),
    ]
}

enum Format {
    static func size(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1000 && index < units.count - 1 { value /= 1000; index += 1 }
        if index == 0 { return "\(Int(value)) B" }
        return String(format: value < 10 ? "%.2f %@" : "%.1f %@", value, units[index])
    }

    /// 相对时间：今天 / 昨天 / N 天前 / —。列表里一眼看出“多久没动”。
    static func age(_ date: Date?) -> String {
        guard let date else { return "—" }
        let days = Int(Date().timeIntervalSince(date) / 86400)
        let months = days / 30
        let years = days / 365
        switch days {
        case ..<1: return t("today")
        case 1: return t("yesterday")
        case 2..<30: return t("%d days ago", days)
        case 30..<365: return months == 1 ? t("1 month ago") : t("%d months ago", months)
        default: return years == 1 ? t("1 year ago") : t("%d years ago", years)
        }
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 界面上显示路径时把主目录缩成 ~
    static func short(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

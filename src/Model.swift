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
        case .size: return "大小"
        case .lastOpened: return "上次打开"
        case .openCount: return "打开次数"
        case .nameAsc: return "应用"
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
        case .container: return "容器"
        case .groupContainer: return "共享容器"
        case .appScripts: return "脚本目录"
        case .preferences: return "偏好"
        case .savedState: return "窗口状态"
        case .cache: return "缓存"
        case .httpStorage: return "网络缓存"
        case .webkit: return "网页数据"
        case .applicationSupport: return "应用支持"
        case .crashReporter: return "崩溃报告"
        case .logs: return "日志"
        case .launchAgent: return "自启/服务"
        case .systemLibrary: return "系统级残留"
        case .helperTool: return "特权工具"
        case .packageReceipt: return "安装包收据"
        case .iCloudContainer: return "iCloud 数据"
        }
    }

    var explain: String {
        switch self {
        case .container: return "沙盒应用自己的数据目录，聊天记录、数据库、下载的素材都在里面。"
        case .groupContainer: return "同一个开发者的一组应用共享的目录，卸载时要看里面还有没有别的应用在用。"
        case .appScripts: return "沙盒应用跑脚本时用的目录，空目录居多。"
        case .preferences: return "偏好设置。删了应用下次打开就是默认设置。"
        case .savedState: return "窗口位置与展开状态，删了下次打开回到默认。"
        case .cache: return "应用自己攒的缓存，删了它会重新生成。"
        case .httpStorage: return "网络请求缓存与 cookie，删了需要重新登录的应用会要求再登录。"
        case .webkit: return "应用内嵌网页的本地数据（localStorage、缓存）。"
        case .applicationSupport: return "应用的支持目录：插件、模板、本地数据库常在这里。"
        case .crashReporter: return "旧版崩溃报告，留着只是占地方。"
        case .logs: return "应用写的日志。"
        case .launchAgent: return "开机自启或常驻的后台服务。卸载时必须一起处理，否则重启后它会试图拉起已经不存在的应用。"
        case .systemLibrary: return "装在 /Library 下的系统级文件，删除需要管理员密码。"
        case .helperTool: return "为提权安装的帮助工具，删除需要管理员密码。"
        case .packageReceipt: return "系统记着「这个应用是用安装包装的」。留着不影响使用，清掉才叫干净。"
        case .iCloudContainer: return "iCloud Drive 里属于这个应用的目录。删掉会同步到你的其他设备，不只是这台。"
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
        case .idPrefix: return "bundle id 前缀"
        case .appGroup: return "App Group"
        case .appName: return "应用名"
        case .loginItem: return "自启项"
        case .packageReceipt: return "包收据"
        }
    }

    var explain: String {
        switch self {
        case .exactID: return "目录名与应用的 bundle id 完全一致。"
        case .idPrefix: return "目录名以 bundle id 开头，是它的帮助程序或子组件。"
        case .appGroup: return "应用签名里声明的共享容器 id。"
        case .appName: return "按应用名匹配到的同名目录，目录内容里读到了这个应用的标识。"
        case .loginItem: return "应用包里声明过的自启项 label。"
        case .packageReceipt: return "系统安装包记录里的收据 id。"
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
        if isAppBundle { return "应用本体（\(appPath)）" }
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
        .init(name: "保护名单", detail: "系统目录、Apple 自带应用、iCloud 同步根目录、工具自己的日志一律不动"),
        .init(name: "路径形态", detail: "必须存在、不是符号链接、落在允许的目录里、层级不过浅"),
        .init(name: "同一磁盘", detail: "只动应用所在的那块磁盘，别的磁盘与网络卷不碰"),
        .init(name: "应用已退出", detail: "应用或它的帮助程序还在跑就先退掉；退不掉就不动它"),
        .init(name: "不误伤", detail: "同一批里既有父目录又有子目录时只留父目录；共享容器里有别的应用就不动"),
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
        switch days {
        case ..<1: return "今天"
        case 1: return "昨天"
        case 2..<30: return "\(days) 天前"
        case 30..<365: return "\(days / 30) 个月前"
        default: return "\(days / 365) 年前"
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

// 多语言：英文是基准字串，中文是翻译表。
// 为什么要自带一层而不是用 .lproj/.strings：这个工程用 swiftc 直接编，没有 Xcode 工程，
// String Catalog 编不进来；一张表 + 一个查找函数足够，也方便别人加语言（复制一张表即可）。
//
// 用法：
//   Text(t("Permissions"))                    // 普通字串
//   Text(t("%d apps installed", count))       // 带参数（%@ / %d，见 String(format:)）
// 语言解析顺序：用户选的 → 系统语言（中文则中文）→ 英文。

import Foundation

enum Lang: String, CaseIterable, Identifiable {
    case en
    case zh

    var id: String { rawValue }

    /// 语言菜单里显示的名字：用各自语言书写（English / 简体中文），习惯如此。
    var label: String {
        switch self {
        case .en: return "English"
        case .zh: return "简体中文"
        }
    }
}

/// 全项目直接用：t("English text") / t("%d items", count)
func t(_ key: String) -> String { Str.t(key) }
func t(_ key: String, _ args: CVarArg...) -> String { Str.t(key, args) }

enum Str {
    /// 当前语言。默认英文；"followSystem" 时按系统语言判断。
    static var current: Lang = .en {
        didSet { UserDefaults.standard.set(current.rawValue, forKey: "lang") }
    }

    /// 初始化：读用户选择；没选过就默认英文（README 与截图都以英文为准）。
    static func bootstrap() {
        if let saved = UserDefaults.standard.string(forKey: "lang"), let lang = Lang(rawValue: saved) {
            current = lang
        } else {
            current = .en
        }
    }

    static func use(_ lang: Lang) { current = lang }

    /// 取一个字串：英文基准，中文时查表；查不到就返回英文原文。
    static func t(_ key: String) -> String {
        guard current == .zh else { return key }
        return zh[key] ?? key
    }

    /// 带参数：先查表，再用 String(format:) 填。
    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    /// 中文翻译表（键 = 英文原文）。加语言就复制这张表。
    private static let zh: [String: String] = [
        "FullCleaner": "全量卸载",
        "Permissions": "权限",
        "%d apps installed · %@ total": "%d 个应用 · 合计 %@",
        "Rescan": "重新扫描",
        "Scanning…": "正在扫描…",
        "%d apps found · %@": "已找到 %d 个 · %@",
        "Search apps": "搜索应用",
        "Show system apps (%d)": "显示系统自带（%d）",
        "Clear selection": "全部取消",
        "App": "应用",
        "Size": "大小",
        "Last opened": "上次打开",
        "Opens": "打开次数",
        "Leftovers": "残留",
        "Sort by “%@” — click again to reverse": "按「%@」排序，再点一次换方向",
        "Not sortable: this column is counted in the background": "不给排序：这一列的数字是后台一条条数出来的",
        "%d selected · %@": "已选 %d 个 · %@",
        "Open log folder": "打开日志目录",
        "Next": "下一步",
        "No matching apps": "没有匹配的应用",
        "%d leftovers": "残留 %d 处",
        "System": "系统自带",
        "Admin": "需要管理员",
        "Last opened %@": "上次打开 %@",
        "%d opens": "打开 %d 次",
        "Permissions are all granted": "权限都齐了",
        "Missing: %@ (open to request)": "还差：%@（点开逐项申请）",
        "Only these are actually used. Accessibility and Input Monitoring are not needed and are never requested.": "只有下面这些是这个工具真正用到的。辅助功能、输入监控这类它不需要，所以不申请。",
        "Full Disk Access": "完全磁盘访问",
        "Files and Folders (Music / Movies / Pictures / Documents / iCloud Drive)": "文件与文件夹（音乐 / 影片 / 图片 / 文稿 / iCloud Drive）",
        "App Management": "App 管理",
        "Read inside other apps' containers — that is how a folder named after an app is verified to belong to it, and how leftover sizes are measured. Without it macOS asks repeatedly, or reads come back incomplete.": "读取其他应用的容器内容：核对「按名字匹配」的目录到底是不是它的，以及量残留体积。没有它，macOS 会逐次弹窗，或者读不全。",
        "Those locations make macOS prompt once. Full Disk Access covers them all; without it this app skips them entirely instead of interrupting you.": "扫到这些位置时 macOS 会弹窗问一次。给了完全磁盘访问就一并覆盖，不会再有零散弹窗；没给就整段跳过，不打扰你。",
        "Move another app's bundle to the Trash. Since macOS 13, modifying a bundle you do not own requires it.": "把其他应用的本体移到废纸篓。macOS 13 起，改动别的应用包需要这一项。",
        "System Settings → Privacy & Security → Full Disk Access → switch FullCleaner on (this one covers all of the above)": "系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 打开 FullCleaner 的开关（这一项管住上面所有位置）",
        "System Settings → Privacy & Security → App Management → switch FullCleaner on": "系统设置 → 隐私与安全性 → App 管理 → 打开 FullCleaner 的开关",
        "Granted": "已授权",
        "Not granted": "未授权",
        "Can't tell yet": "检测不了",
        "Request": "去申请",
        "Waiting for macOS…": "在等系统放行…",
        "Check again": "重新检查",
        "Done": "好",
        "Language": "语言",
        "Follow system": "跟随系统",
        "Deep-scanning leftovers": "正在深度扫描残留",
        "Uninstall %d apps · %d items · %@": "卸载 %d 个应用 · 移除 %d 项 · %@",
        "%d/%d items · %@": "%d/%d 项 · %@",
        "%d blocked": "拦下 %d 项",
        "%d items couldn't be attributed — skipped": "另有 %d 项无法确认归属，已跳过",
        "Cancel": "取消",
        "Uninstall %d items": "卸载这 %d 项",
        "Preparing…": "准备开始…",
        "Uninstalling…": "正在卸载…",
        "%d items removed": "已移除 %d 项",
        "Nothing to remove": "没有要移除的东西",
        "%@ went to the Trash — you can drag it back": "%@ 进了废纸篓，随时可以拖回来",
        "%d items were left alone: %@": "有 %d 项没动：%@",
        "1 item removed": "已移除 1 项",
        "1 item was left alone: %@": "有 1 项没动：%@",
        "Open Trash": "打开废纸篓",
        "Open log": "打开日志",
        "Scanning installed apps…": "正在扫描已安装的应用…",
        "No apps found": "没有找到应用",
        "Nothing left to delete was found": "没有找到可以删的东西",
        "Preparing the list…": "正在准备清单…",
        "Scanning %@…": "正在扫描 %@…",
        "Scanning %@ · %d found": "正在扫描 %@ · 已找到 %d 项",
        "Finding leftovers and measuring them…": "正在找残留并量体积…",
        "Container": "容器",
        "Group container": "共享容器",
        "Scripts folder": "脚本目录",
        "Preferences": "偏好",
        "Window state": "窗口状态",
        "Cache": "缓存",
        "Web storage": "网络缓存",
        "WebKit data": "网页数据",
        "Application support": "应用支持",
        "Crash reporter": "崩溃报告",
        "Logs": "日志",
        "Launch agent": "自启/服务",
        "System-level leftover": "系统级残留",
        "Helper tool": "特权工具",
        "Package receipt": "安装包收据",
        "iCloud data": "iCloud 数据",
        "The app's own sandbox container: chat history, databases, downloaded assets.": "沙盒应用自己的数据目录，聊天记录、数据库、下载的素材都在里面。",
        "Shared between apps from the same developer — check whether another app still uses it.": "同一个开发者的一组应用共享的目录，卸载时要看里面还有没有别的应用在用。",
        "Where a sandboxed app keeps its scripts; usually empty.": "沙盒应用跑脚本时用的目录，空目录居多。",
        "Preferences. Delete them and the app starts from defaults.": "偏好设置。删了应用下次打开就是默认设置。",
        "Window position and expansion state.": "窗口位置与展开状态，删了下次打开回到默认。",
        "Cache the app built up; it will recreate it.": "应用自己攒的缓存，删了它会重新生成。",
        "HTTP cache and cookies. Apps that need a login may ask again.": "网络请求缓存与 cookie，删了需要重新登录的应用会要求再登录。",
        "Local data of web views inside the app.": "应用内嵌网页的本地数据（localStorage、缓存）。",
        "Plugins, templates and local databases often live here.": "应用的支持目录：插件、模板、本地数据库常在这里。",
        "Old crash reports — they only take up space.": "旧版崩溃报告，留着只是占地方。",
        "Logs written by the app.": "应用写的日志。",
        "Launch-at-login or background service. It has to go with the app, otherwise it keeps trying to start something that no longer exists.": "开机自启或常驻的后台服务。卸载时必须一起处理，否则重启后它会试图拉起已经不存在的应用。",
        "Files installed under /Library; removing them needs an administrator.": "装在 /Library 下的系统级文件，删除需要管理员密码。",
        "A privileged helper installed for the app; removing it needs an administrator.": "为提权安装的帮助工具，删除需要管理员密码。",
        "macOS remembers the app was installed from a package. Harmless to keep, but a clean uninstall forgets it.": "系统记着「这个应用是用安装包装的」。留着不影响使用，清掉才叫干净。",
        "Data this app keeps in iCloud Drive. Deleting it affects your other devices, not just this Mac.": "iCloud Drive 里属于这个应用的目录。删掉会同步到你的其他设备，不只是这台。",
        "bundle id": "bundle id",
        "bundle id prefix": "bundle id 前缀",
        "App Group": "App Group",
        "app name": "应用名",
        "login item": "自启项",
        "package receipt": "包收据",
        "The folder name is exactly the app's bundle id.": "目录名与应用的 bundle id 完全一致。",
        "The folder name starts with the bundle id — a helper or sub-component.": "目录名以 bundle id 开头，是它的帮助程序或子组件。",
        "A shared container id declared in the app's own signature.": "应用签名里声明的共享容器 id。",
        "Matched by app name, and the app's bundle id was read inside the folder.": "按应用名匹配到的同名目录，目录内容里读到了这个应用的标识。",
        "A launch-item label declared inside the app bundle.": "应用包里声明过的自启项 label。",
        "A receipt id from macOS's installer records.": "系统安装包记录里的收据 id。",
        "Protected paths": "保护名单",
        "Path shape": "路径形态",
        "Same volume": "同一磁盘",
        "App already quit": "应用已退出",
        "No collateral damage": "不误伤",
        "System paths, Apple's apps, iCloud container roots and the tool's own logs are never touched.": "系统目录、Apple 自带应用、iCloud 同步根目录、工具自己的日志一律不动。",
        "Must exist, must not be a symlink, must stay inside an allow-list after resolving links, and must not be too shallow.": "必须存在、不是符号链接、落在允许的目录里、层级不过浅。",
        "Only the disk the app lives on; other disks and network volumes are left alone.": "只动应用所在的那块磁盘，别的磁盘与网络卷不碰。",
        "The app and its helpers must be gone first; if they will not quit, nothing is removed.": "应用或它的帮助程序还在跑就先退掉；退不掉就不动它。",
        "A parent and its child in the same batch keeps only the parent; a container two apps share is never removed.": "同一批里既有父目录又有子目录时只留父目录；共享容器里有别的应用就不动。",
        "System app or Apple app": "系统自带或 Apple 的应用",
        "Name looks similar, no evidence found": "只有名字像，没有证据",
        "iCloud data — deleting it would affect your other devices": "iCloud 数据，删了其他设备也会少",
        "Other apps still use it (%@)": "还有别的应用在用（%@）",
        "Other apps still use it (%@) — deleting it would break them": "还有别的应用在用它（%@），删了它们会出问题",
        "This is a protected path itself": "这是受保护的目录本身",
        "Not inside the directories this tool may delete from": "不在本工具允许删除的目录里",
        "macOS's own preference file — not touched": "系统自己的偏好设置，不动",
        "This app is not in a standard app folder (/Applications or ~/Applications)": "这个应用不在标准应用目录（/Applications 或 ~/Applications）里，本工具不动它",
        "Built-in system app, protected by SIP": "系统自带应用受 SIP 保护",
        "This is a symlink — not deleted": "这是符号链接，不删",
        "Path does not exist any more": "路径已不存在",
        "Not an absolute path": "不是绝对路径",
        "Path contains .. — not deleted": "路径里有 ..，不删",
        "The app lives on another disk; cross-volume items are not touched": "应用不在同一块磁盘上，跨盘的东西不删",
        "Its parent folder is being deleted too — the parent is enough": "它的上级目录这次也要删，删上级就够了",
        "%@ also selected this one; when two apps claim a path, neither is deleted": "%@ 那边也勾了这一条，两边都想删的目录本工具不动",
        "Only the name matches and nothing else was found — not deleted": "只有名字一样，没有别的证据，不删",
        "Move to Trash": "移到废纸篓",
        "Administrator action": "管理员操作",
        "Verification": "复核",
        "Still there after deletion": "删完路径还在",
        "Could not quit every process (quit it in Activity Monitor, or uninstall after a restart)": "还有进程没退掉（可以在活动监视器里退出，或者重启后再卸）",
        "Nothing was running": "没有在运行",
        "Quit": "已退出",
        "Not built yet": "还没构建",
        "the administrator prompt was not granted (maybe cancelled)": "没拿到管理员授权（可能取消了密码框）",
        "the command failed": "命令返回失败",
        "%d apps installed": "已装 %d 个应用",
        "Permissions (this tool only uses these)": "权限（这个工具只用这两项）",
        "Not found: “%@”. Try --list to see what is installed.": "没找到「%@」。用 --list 看看有哪些应用。",
        "Add --yes to actually delete. Run --plan %@ first to see the list.": "要真删得加 --yes。先跑 --plan %@ 看一眼清单。",
        "Items in the plan (%d, ★ = selected):": "清单（%d 项，★ = 默认勾选）：",
        "Skipped %d items (uncertain, or not safe to remove):": "跳过 %d 项（归属拿不准或不能动，不删）：",
        "Blocked %d items (not deleted):": "被拦下 %d 项（不会删）：",
        "Would remove %d items · %@; this command only prints the list.": "会删 %d 项 · %@；这里只出清单，没动任何文件。",
        "%d items removed · %@": "移除 %d 项 · %@",
        "Log: %@": "日志：%@",
        "today": "今天",
        "yesterday": "昨天",
        "%d days ago": "%d 天前",
        "%d months ago": "%d 个月前",
        "%d years ago": "%d 年前",
        "1 month ago": "1 个月前",
        "1 year ago": "1 年前",
        "1 day ago": "1 天前",
        "App bundle (%@)": "应用本体（%@）",
        "%@ is a system or Apple app": "%@ 是系统自带或 Apple 的应用",
        "Evidence: %@.": "判据：%@。",
        "found “%@” inside": "文件里写到了 %@",
        "a file named after %@": "目录里有以 %@ 命名的文件",
        "Quitting %@…": "正在退出 %@…",
        "Unloading launch agent %@…": "卸掉自启项 %@…",
        "%d processes would not quit (quit them in Activity Monitor, or uninstall after a restart)": "还有 %d 个进程没退掉（可以在活动监视器里退出，或者重启后再卸）",
        "Reset permission record: %@": "重置了权限记录：%@",
        "Resetting permission records (%d)": "重置权限记录（%d 条）",
        "%d items need an administrator (one password prompt)": "需要管理员权限：%d 项（可能会弹一次密码框）",
        "Self-test: skipping app quit": "自检：跳过退出应用的步骤",
        "Self-test: skipping permission reset": "自检：跳过权限记录重置",
        "Self-test: skipping pkgutil --forget": "自检：跳过 pkgutil --forget",
        "Shared between apps from the same developer — check that nothing else uses it.": "这个目录由同开发者的多个应用共享，先确认里面没有别的应用在用。",
        "Deleting it also affects your other devices signed in with the same Apple ID.": "删掉会同步到你登录同一 Apple ID 的其他设备。",
        "Size needs Full Disk Access (not granted, so it is left blank).": "体积要完全磁盘访问才能量（现在没给，所以留空）。",
        "App bundle": "应用本体",
        "Removed %d items · %@": "移除 %d 项 · %@",
        "System apps are protected by SIP — this tool does not uninstall them, it just shows them": "系统自带的应用受 SIP 保护，本工具不卸载，只列出来让你看清全貌",
        "Render failed": "渲染失败",
        "Rendered the interface to %@": "界面已渲染到 %@",
        "Rendered the plan to %@": "清单已渲染到 %@",
        "Rendered the permissions panel to %@": "权限面板已渲染到 %@",
        "Rendered the result sheet to %@": "结果页已渲染到 %@",
    ]
}

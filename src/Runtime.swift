// 运行环境：路径解析、外部命令、停止开关、以及自检用的"虚拟根"。
// 所有会动文件的地方都从这里拿路径，方便自检把整个家目录指到临时样本目录。

import Foundation

/// 停止开关（扫描、量体积都看它）。
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var stopped: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

enum Shell {
    /// 跑一个外部命令拿回退出码与标准输出。读管道用 readabilityHandler，
    /// 否则 availableData 会阻塞到进程结束，界面上的「停止」要等它跑完才响应。
    @discardableResult
    static func run(_ executable: String, _ args: [String],
                    timeout: TimeInterval = 60, stop: StopFlag? = nil) -> (status: Int32, output: String) {
        Trace.mark("run \(executable) \(args.prefix(2).joined(separator: " "))")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let lock = NSLock()
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); buffer.append(chunk); lock.unlock()
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (-1, "")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if stop?.stopped == true || Date() > deadline {
                process.terminate()
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        process.waitUntilExit()
        // 收尾：让 handler 把剩下的读完
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { lock.lock(); buffer.append(rest); lock.unlock() }
        let text = String(data: buffer, encoding: .utf8) ?? ""
        return (process.terminationStatus, text)
    }
}

enum Paths {
    /// 自检会把 HOME 指到临时样本目录（FULLCLEANER_HOME）。
    static var home: String {
        if let override = ProcessInfo.processInfo.environment["FULLCLEANER_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL.path
        }
        return NSHomeDirectory()
    }

    /// 系统级路径（/Library、/Applications）在自检里映射到临时目录，免得动到真系统。
    static var systemRoot: String? {
        ProcessInfo.processInfo.environment["FULLCLEANER_SYSTEM_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 把系统绝对路径映射到虚拟根下。
    static func system(_ path: String) -> String {
        guard let root = systemRoot else { return path }
        return root + path
    }

    /// 界面上显示时映射回来。
    static func display(_ path: String) -> String {
        var text = path
        if let root = systemRoot, text.hasPrefix(root) { text = String(text.dropFirst(root.count)) }
        if text.hasPrefix(home) { text = "~" + text.dropFirst(home.count) }
        return text
    }

    static var library: String { home + "/Library" }
    static var applications: String { home + "/Applications" }

    /// 要找残留的地方（用户级）。
    static var userRoots: [String] {
        [
            library + "/Containers",
            library + "/Group Containers",
            library + "/Application Scripts",
            library + "/Preferences",
            library + "/Preferences/ByHost",
            library + "/Saved Application State",
            library + "/Caches",
            library + "/HTTPStorages",
            library + "/WebKit",
            library + "/Application Support",
            library + "/Application Support/CrashReporter",
            library + "/Logs",
            library + "/Logs/DiagnosticReports",
            library + "/Autosave Information",
            library + "/LaunchAgents",
            library + "/Mobile Documents",
        ]
    }

    /// 系统级残留所在的地方（需要管理员）。
    static var systemRoots: [String] {
        [
            system("/Library/Application Support"),
            system("/Library/Caches"),
            system("/Library/Logs"),
            system("/Library/Preferences"),
            system("/Library/LaunchAgents"),
            system("/Library/LaunchDaemons"),
            system("/Library/PrivilegedHelperTools"),
        ]
    }

    static var logDirectory: String {
        let base = library + "/Logs/fullcleaner"
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }

    /// 允许删除的根（白名单）。清单里的路径必须落在其中一条之下。
    static var deletionRoots: [String] {
        var roots = [
            library + "/Containers", library + "/Group Containers", library + "/Application Scripts",
            library + "/Preferences", library + "/Saved Application State", library + "/Caches",
            library + "/HTTPStorages", library + "/WebKit", library + "/Application Support",
            library + "/Logs", library + "/Autosave Information", library + "/LaunchAgents",
            applications,
        ]
        roots.append(contentsOf: [
            system("/Applications"), system("/Applications/Utilities"),
            system("/Library/Application Support"), system("/Library/Caches"), system("/Library/Logs"),
            system("/Library/Preferences"), system("/Library/LaunchAgents"), system("/Library/LaunchDaemons"),
            system("/Library/PrivilegedHelperTools"),
        ])
        return roots
    }

    /// 永远不动的路径：即使用户手滑也拦下。
    static var neverTouch: [String] {
        var list = [
            "/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/private/var", "/var", "/Volumes",
            "/Applications", "/Library", "/Users",
            home, library, library + "/Mobile Documents", library + "/Preferences",
            home + "/Documents", home + "/Desktop", home + "/Downloads", home + "/Pictures", home + "/Movies",
            home + "/Music", home + "/Public", home + "/.Trash",
        ]
        if let root = systemRoot {
            list.append(contentsOf: [root, root + "/Applications", root + "/Library", root + "/Library/Preferences"])
        }
        return list
    }

    /// 应用扫描的目录。自检用 FULLCLEANER_APP_DIRS 指到样本目录。
    static var appDirectories: [String] {
        if let override = ProcessInfo.processInfo.environment["FULLCLEANER_APP_DIRS"], !override.isEmpty {
            return override.split(separator: ":").map(String.init)
        }
        return [
            "/Applications",
            home + "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
        ].map { $0.hasPrefix("/System") ? system($0) : ($0.hasPrefix(home) ? $0 : $0) }
    }

    static var trash: String { home + "/.Trash" }
}

enum Sandbox {
    /// 自检：不给 root 权限、不碰真系统的权限数据库。
    static var adminDisabled: Bool { ProcessInfo.processInfo.environment["FULLCLEANER_NO_ADMIN"] == "1" }
    static var tccDisabled: Bool { ProcessInfo.processInfo.environment["FULLCLEANER_NO_TCC"] == "1" }

    /// 是不是在自检里跑（界面与 CLI 都据此改口径）。
    static var isSelfTest: Bool { ProcessInfo.processInfo.environment["FULLCLEANER_SELFTEST"] == "1" }
}

/// 量目录体积：按文件实际占用的块数算（跟 Finder 的「大小」一致）。
enum Sizer {
    static func bytes(of path: String, stop: StopFlag? = nil) -> Int64 {
        Trace.mark("size \(path)")
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return allocatedSize(of: url)
        }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys,
            options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            if stop?.stopped == true { break }
            guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func allocatedSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
    }

    static func modified(of path: String) -> Date? {
        Trace.mark("mod \(path)")
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

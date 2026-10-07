// 追踪：排查系统弹窗（TCC）是哪一步引起的。
// 默认关闭；打开方式：defaults write local.fullcleaner debugTrace -bool YES
// 然后把每一步写进 ~/Library/Logs/fullcleaner/trace.log，跟系统日志里弹窗的时间对一下就知道是谁碰的。

import Foundation

enum Trace {
    private static var enabled: Bool = UserDefaults.standard.bool(forKey: "debugTrace")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 打开时要重新读一次（改 pref 后不重启也能生效）。
    static func refresh() { enabled = UserDefaults.standard.bool(forKey: "debugTrace") }

    static func mark(_ text: String) {
        guard enabled || UserDefaults.standard.bool(forKey: "debugTrace") else { return }
        let line = "\(formatter.string(from: Date())) \(text)\n"
        let path = Paths.logDirectory + "/trace.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

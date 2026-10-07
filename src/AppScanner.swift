// 扫描已安装的应用：找出 .app、量体积、读 bundle id 与签名里的容器声明。
// 只读，不改任何东西。

import Foundation
import Security
import AppKit
import CoreServices

enum AppScanner {

    /// 扫描目录 + 它是不是系统自带（系统目录要标出来，界面上不给删）。
    private static var specs: [(path: String, isSystem: Bool)] {
        if let override = ProcessInfo.processInfo.environment["FULLCLEANER_APP_DIRS"], !override.isEmpty {
            return override.split(separator: ":").map { (String($0), false) }
        }
        return [
            ("/Applications", false),
            (Paths.home + "/Applications", false),
            (Paths.system("/System/Applications"), true),
            (Paths.system("/System/Applications/Utilities"), true),
        ]
    }

    static func scan(stop: StopFlag? = nil, onEach: ((AppItem) -> Void)? = nil) -> [AppItem] {
        var found: [AppItem] = []
        var seen = Set<String>()
        for spec in specs {
            for path in appBundles(in: spec.path) {
                if stop?.stopped == true { break }
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                guard let item = describe(path: path, isSystem: spec.isSystem) else { continue }
                found.append(item)
                onEach?(item)
            }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 目录本身、以及目录下一层的子目录里的 .app（有些安装包会把应用放进子文件夹）。
    private static func appBundles(in directory: String) -> [String] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory) else { return [] }
        var results: [String] = []
        let top = (try? manager.contentsOfDirectory(atPath: directory)) ?? []
        for entry in top.sorted() where !entry.hasPrefix(".") {
            let path = directory + "/" + entry
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if entry.hasSuffix(".app") {
                results.append(path)
                continue
            }
            // 一层子目录：Adobe / Microsoft Office 这类
            let nested = (try? manager.contentsOfDirectory(atPath: path)) ?? []
            for child in nested.sorted() where child.hasSuffix(".app") {
                results.append(path + "/" + child)
            }
        }
        return results
    }

    /// 把一个 .app 描述成 AppItem。信息不全（没有 bundle id）就当它不是应用。
    static func describe(path: String, isSystem: Bool) -> AppItem? {
        let infoPath = path + "/Contents/Info.plist"
        guard let info = NSDictionary(contentsOfFile: infoPath) as? [String: Any] else { return nil }
        let bundleID = (info["CFBundleIdentifier"] as? String) ?? ""
        guard !bundleID.isEmpty else { return nil }
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? fileName
        let entitlements = entitlements(of: path)
        let groups = (entitlements["com.apple.security.application-groups"] as? [String]) ?? []
        let iCloud = (entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]) ?? []
        let nested = nestedBundleIDs(inside: path)
        let labels = loginItemLabels(inside: path)
        let owner = (try? FileManager.default.attributesOfItem(atPath: path))?[.ownerAccountName] as? String

        return AppItem(
            path: path,
            bundleID: bundleID,
            name: name,
            version: (info["CFBundleShortVersionString"] as? String) ?? "",
            bytes: Sizer.bytes(of: path),
            isSystem: isSystem || path.hasPrefix(Paths.system("/System/")),
            isMAS: FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt"),
            rootOwned: owner == "root" || !FileManager.default.isDeletableFile(atPath: path),
            executableName: (info["CFBundleExecutable"] as? String) ?? fileName,
            nestedBundleIDs: nested,
            loginItemLabels: labels,
            appGroups: groups,
            iCloudContainers: iCloud,
            modified: Sizer.modified(of: path),
            lastOpened: lastOpened(path: path, executable: (info["CFBundleExecutable"] as? String) ?? fileName),
            openCount: openCount(path: path),
            iconPath: path)
    }

    /// 上次打开：Spotlight 的 kMDItemLastUseDate 在多数机器上是空的，
    /// 可执行文件的访问时间（APFS 会更新）是可靠的近似——应用一启动，系统就读这个文件。
    static func lastOpened(path: String, executable: String) -> Date? {
        if let item = MDItemCreateWithURL(nil, URL(fileURLWithPath: path) as CFURL),
           let value = MDItemCopyAttribute(item, "kMDItemLastUseDate" as CFString) as? Date {
            return value
        }
        let exe = path + "/Contents/MacOS/" + executable
        return (try? URL(fileURLWithPath: exe).resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
    }

    /// 打开次数：Spotlight 的使用计数（kMDItemUseCount），没有索引时为 nil。
    static func openCount(path: String) -> Int? {
        guard let item = MDItemCreateWithURL(nil, URL(fileURLWithPath: path) as CFURL),
              let value = MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) else { return nil }
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    /// 签名里声明的授权（App Group、iCloud 容器都在这里）。
    static func entitlements(of path: String) -> [String: Any] {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return [:] }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return [:] }
        return (dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]) ?? [:]
    }

    /// 应用包内的子程序（登录项、帮助程序、扩展）各自的 bundle id —— 它们在系统里也有自己的权限条目。
    static func nestedBundleIDs(inside path: String) -> [String] {
        var ids: [String] = []
        let manager = FileManager.default
        let roots = ["Contents/Library/LoginItems", "Contents/Helpers", "Contents/XPCServices",
                     "Contents/PlugIns", "Contents/Library/LaunchServices", "Contents/Frameworks"]
        for root in roots {
            let directory = path + "/" + root
            guard manager.fileExists(atPath: directory) else { continue }
            let entries = (try? manager.contentsOfDirectory(atPath: directory)) ?? []
            for entry in entries {
                let child = directory + "/" + entry
                let infoPath = child + "/Contents/Info.plist"
                if let info = NSDictionary(contentsOfFile: infoPath) as? [String: Any],
                   let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty {
                    ids.append(identifier)
                }
            }
        }
        return Array(Set(ids)).sorted()
    }

    /// 应用包内自带的自启项 label（Contents/Library/LaunchAgents/*.plist）。
    static func loginItemLabels(inside path: String) -> [String] {
        let manager = FileManager.default
        let directory = path + "/Contents/Library/LaunchAgents"
        guard manager.fileExists(atPath: directory) else { return [] }
        let entries = (try? manager.contentsOfDirectory(atPath: directory)) ?? []
        return entries.compactMap { entry -> String? in
            guard entry.hasSuffix(".plist") else { return nil }
            let full = directory + "/" + entry
            if let plist = NSDictionary(contentsOfFile: full) as? [String: Any],
               let label = plist["Label"] as? String, !label.isEmpty {
                return label
            }
            return (entry as NSString).deletingPathExtension
        }.sorted()
    }
}

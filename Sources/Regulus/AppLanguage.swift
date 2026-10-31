import AppKit
import Foundation

/// 界面语言：写进本 App 自己的 `AppleLanguages`，重新打开后生效（系统菜单也一起变）；「跟随系统」就删掉这个键
/// The UI language: stored as this app's own `AppleLanguages` and applied on relaunch (system menus follow too);
/// "same as system" removes the key.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: Self { self }

    /// 语言名用各自的语言写，不翻译 / Each language is named in itself, untranslated.
    var title: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    /// 本次启动时的设置，与它不同就要重新打开 / The choice at this launch; a different one needs a relaunch.
    static let atLaunch = saved

    private static let key = "AppleLanguages"

    /// 当前保存的设置。只读本 App 的域：`UserDefaults.standard` 会落到全局的系统语言列表上
    /// The saved choice. Reads only this app's domain: `UserDefaults.standard` would fall through to the global list.
    static var saved: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let codes = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String],
              let code = codes.first else { return .system }
        return AppLanguage(rawValue: code) ?? .system
    }

    func save() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Self.key)
        }
    }

    /// 退出并重新打开 App：后台脚本等本进程退出后再 open / Quit and reopen: a background script waits for this
    /// process to exit, then opens the app again.
    static func relaunch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 路径作为位置参数传入，不拼进脚本 / the path is passed as a positional argument, never spliced into the script
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$2\"", "sh",
                             String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        try process.run()
        NSApp.terminate(nil)
    }
}

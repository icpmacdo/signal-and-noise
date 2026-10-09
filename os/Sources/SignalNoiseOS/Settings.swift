import Foundation
import MaskCore
import Security

struct Settings: Codable, Equatable {
  var enabled = true
  var picked = Bubbles.defaultPicked
  var customs: [String] = []
  var threshold = 0.6
  var mode = Mode.tiles
  var grid = GridSpec(cols: 8, rows: 5)
  /// Apps whose windows are never captured, and while one is in front nothing runs at all.
  var neverApps = [
    "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
    "com.apple.Passwords", "com.apple.keychainaccess", "com.apple.systempreferences",
  ]

  var bubbles: [Bubble] { Bubbles.active(picked: picked, customs: customs) }

  static func load() -> Settings {
    guard let data = UserDefaults.standard.data(forKey: "settings"),
          let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
    return s
  }

  func save() {
    if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "settings") }
  }
}

/// The OpenAI key lives in the login keychain. OPENAI_API_KEY or ~/.config/openai/api_key also work,
/// which is handy when running from a terminal.
enum KeyStore {
  static let service = "signal-and-noise-os"
  static let account = "openai"

  static func load() -> String {
    var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                            kSecAttrAccount as String: account, kSecReturnData as String: true]
    var out: AnyObject?
    if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
       let k = String(data: d, encoding: .utf8), !k.isEmpty { return k }
    q.removeValue(forKey: kSecReturnData as String)
    if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty { return env }
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/openai/api_key")
    return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  static func save(_ key: String) {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                            kSecAttrAccount as String: account]
    SecItemDelete(q as CFDictionary)
    guard !key.isEmpty else { return }
    var add = q
    add[kSecValueData as String] = Data(key.utf8)
    SecItemAdd(add as CFDictionary, nil)
  }
}

/// Plain-text log of every judging pass, for tuning: ~/Library/Logs/SignalNoiseOS.log
enum Log {
  static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SignalNoiseOS.log")

  static func write(_ line: String) {
    let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
    if let h = try? FileHandle(forWritingTo: url) {
      h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
    } else {
      try? text.write(to: url, atomically: true, encoding: .utf8)
    }
  }
}

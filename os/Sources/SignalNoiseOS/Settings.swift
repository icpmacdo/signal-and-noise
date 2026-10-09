import Foundation
import MaskCore
import Security

struct Settings: Codable, Equatable {
  var enabled = true
  var picked = Bubbles.defaultPicked
  var customs: [String] = []
  /// The coarse pass only proposes; the zoomed second look decides the shape (and can find
  /// nothing), so the coarse bar sits lower than it would alone.
  var threshold = 0.5
  /// Grid won on real pages (2026-10-09, six sites via OpenRouter): ~0.7 s per screen vs ~1.8 s,
  /// 2 requests vs 40, and it covered more of each ad.
  var mode = Mode.grid
  /// Nil: sized to each display (cells about 220 points across). 8x5 is the default: on WSJ
  /// screenshots from a 6K display it caught the banner and video ads, where 14x8 caught
  /// scattered pieces of them (2026-10-09).
  var grid: GridSpec? = GridSpec(cols: 8, rows: 5)
  /// Reshape masks with a zoomed second look (or SAM 3 on fal.ai when a fal key is set).
  var tighterShapes = true
  /// Apps whose windows are never captured, and while one is in front nothing runs at all.
  var neverApps = [
    "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
    "com.apple.Passwords", "com.apple.keychainaccess", "com.apple.systempreferences",
  ]

  var bubbles: [Bubble] { Bubbles.active(picked: picked, customs: customs) }

  init() {}

  /// Fields added later fall back to their defaults instead of discarding saved settings.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Settings()
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    picked = try c.decodeIfPresent([String].self, forKey: .picked) ?? d.picked
    customs = try c.decodeIfPresent([String].self, forKey: .customs) ?? d.customs
    threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? d.threshold
    mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? d.mode
    grid = c.contains(.grid) ? try c.decodeIfPresent(GridSpec.self, forKey: .grid) : d.grid
    tighterShapes = try c.decodeIfPresent(Bool.self, forKey: .tighterShapes) ?? d.tighterShapes
    neverApps = try c.decodeIfPresent([String].self, forKey: .neverApps) ?? d.neverApps
  }

  static func load() -> Settings {
    guard let data = UserDefaults.standard.data(forKey: "settings"),
          let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
    return s
  }

  func save() {
    if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "settings") }
  }
}

/// Keys live in the login keychain: `openai` (OPENAI_API_KEY or ~/.config/openai/api_key also
/// work, handy from a terminal) and `fal` for SAM (FAL_KEY or ~/.config/fal/api_key).
enum KeyStore {
  static let service = "signal-and-noise-os"

  static func load(_ account: String = "openai") -> String {
    var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                            kSecAttrAccount as String: account, kSecReturnData as String: true]
    var out: AnyObject?
    if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
       let k = String(data: d, encoding: .utf8), !k.isEmpty { return k }
    q.removeValue(forKey: kSecReturnData as String)
    let envName = account == "fal" ? "FAL_KEY" : "OPENAI_API_KEY"
    if let env = ProcessInfo.processInfo.environment[envName], !env.isEmpty { return env }
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/\(account)/api_key")
    return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  static func save(_ key: String, account: String = "openai") {
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

// A small floating panel with what the models have cost while the app runs: per model and in
// total for this session, the last minute (and the hourly rate it implies), and today. Opened
// from the menu; it never takes focus, follows you across Spaces, and remembers where it was put.
// The app leaves its own windows out of every capture, so the panel is never judged.
import AppKit
import MaskCore

@MainActor
final class UsageWidget {
  private let panel: NSPanel
  private let text = NSTextField(labelWithString: "")
  var onClose: (() -> Void)?

  init() {
    panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                    styleMask: [.titled, .closable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                    backing: .buffered, defer: false)
    panel.title = "Signal & Noise · usage"
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    text.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    text.textColor = .labelColor
    text.maximumNumberOfLines = 0
    text.translatesAutoresizingMaskIntoConstraints = false
    let content = NSView()
    content.addSubview(text)
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
      text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
      text.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
      text.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
    ])
    panel.contentView = content
    if !panel.setFrameUsingName("UsageWidget"), let screen = NSScreen.main {
      let v = screen.visibleFrame
      panel.setFrameTopLeftPoint(NSPoint(x: v.maxX - 380, y: v.maxY - 20))
    }
    panel.setFrameAutosaveName("UsageWidget")
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.onClose?() }
    }
  }

  var isVisible: Bool { panel.isVisible }
  func show() { panel.orderFrontRegardless() }
  func close() { panel.close() }

  func update(_ s: UsageMeter.Snapshot) {
    text.attributedStringValue = Self.render(s)
    let size = text.fittingSize
    let top = panel.frame.maxY
    var frame = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: max(320, size.width + 28), height: size.height + 22))
    frame.origin = NSPoint(x: panel.frame.minX, y: top - frame.height)
    if frame.size != panel.frame.size { panel.setFrame(frame, display: true) }
  }

  // MARK: formatting

  static func render(_ s: UsageMeter.Snapshot) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    let bold = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    let dim = NSColor.secondaryLabelColor
    func add(_ str: String, _ font: NSFont = mono, _ color: NSColor = .labelColor) {
      out.append(NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: color]))
    }
    let total = s.sessionTotal
    let minutes = max(0, Int(Date().timeIntervalSince(s.started) / 60))
    add("This session", bold)
    add(" · \(minutes < 1 ? "under a minute" : "\(minutes) min")\n", mono, dim)
    add("\(count(total.requests)) requests · \(tokens(total.inputTokens + total.outputTokens)) tokens · ")
    add("\(money(total.cost, estimated: total.estimated > 0))\n", bold)
    for (model, line) in s.session.sorted(by: { $0.value.cost > $1.value.cost }) {
      // Fully monospaced so the columns line up under each other.
      let cols = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
      let name = Pricing.shortName(model).padding(toLength: 17, withPad: " ", startingAt: 0)
      add("  \(name)", cols, dim)
      let cost = line.unpriced == line.requests && line.cost == 0 ? "no price" : money(line.cost, estimated: line.estimated > 0)
      add("\(left(count(line.requests), 6)) req \(left(tokens(line.inputTokens + line.outputTokens), 7)) tok \(left(cost, 8))", cols)
      if line.failures > 0 { add("  \(line.failures) failed", cols, .systemOrange) }
      add("\n")
    }
    let m = s.lastMinute
    add("Last minute", bold)
    add(" · \(count(m.requests)) requests · \(money(m.cost, estimated: m.estimated > 0)) · about \(money(m.cost * 60, estimated: m.estimated > 0))/hour\n")
    let t = s.todayTotal
    add("Today", bold)
    add(" · \(count(t.requests)) requests · \(tokens(t.inputTokens + t.outputTokens)) tokens · ")
    add(money(t.cost, estimated: t.estimated > 0), bold)
    if total.estimated > 0 || t.estimated > 0 {
      add("\n≈ estimated from list prices (luna $0.10, Jev $0.042 per million input tokens)", NSFont.systemFont(ofSize: 10), dim)
    }
    return out
  }

  /// Right-aligned in `width` columns (the digits are monospaced).
  static func left(_ str: String, _ width: Int) -> String {
    String(repeating: " ", count: max(0, width - str.count)) + str
  }

  static func count(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
  }

  static func tokens(_ n: Int) -> String {
    switch n {
    case ..<1_000: return "\(n)"
    case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000)
    default: return String(format: "%.2fM", Double(n) / 1_000_000)
    }
  }

  static func money(_ d: Double, estimated: Bool) -> String {
    let body = d == 0 ? "$0" : d < 0.01 ? String(format: "$%.4f", d) : d < 1 ? String(format: "$%.3f", d) : String(format: "$%.2f", d)
    return (estimated ? "≈" : "") + body
  }
}

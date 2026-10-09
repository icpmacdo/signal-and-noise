// The menu-bar item, the capture loop and the pause rules.
//
// Every ~350 ms each display is captured (our own masks and the never-capture apps left out, no
// cursor) at one pixel per point and handed to its DisplayWorker. Nothing is captured while it's
// off, without a key or bubbles, while macOS reports secure text entry (a password field has
// focus), or while a never-capture app is in front.
import AppKit
import Carbon
import MaskCore
import ScreenCaptureKit

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var settings = Settings.load()
  private var key = KeyStore.load()
  private var falKey = KeyStore.load("fal")
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private var workers: [CGDirectDisplayID: DisplayWorker] = [:]
  private var content: SCShareableContent?
  private var contentAt = Date.distantPast
  private var loop: Task<Void, Never>?
  private var status = "Starting"
  private var lastPass = ""
  private var paused = true

  /// For testing against a stub: SNOS_DECISIONS_URL=http://127.0.0.1:8787/v1/decisions
  private let decisionsURL = ProcessInfo.processInfo.environment["SNOS_DECISIONS_URL"].flatMap(URL.init(string:)) ?? Decisions.defaultURL
  private let samURL = ProcessInfo.processInfo.environment["SNOS_SAM_URL"].flatMap(URL.init(string:)) ?? SAMClient.defaultURL

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let button = statusItem.button {
      button.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "Signal & Noise")
      button.image?.isTemplate = true
    }
    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu
    if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    Log.write("started; mode \(settings.mode.rawValue), grid \(settings.grid.cols)x\(settings.grid.rows), bubbles \(settings.bubbles.map(\.label))")
    loop = Task { @MainActor in
      while !Task.isCancelled {
        await tick()
        try? await Task.sleep(nanoseconds: 350_000_000)
      }
    }
  }

  // MARK: capture loop

  private func pauseReason() -> String? {
    if !settings.enabled { return "Off" }
    if key.isEmpty && decisionsURL == Decisions.defaultURL { return "Needs an OpenAI key" }
    if settings.bubbles.isEmpty { return "Pick something to hide" }
    if !CGPreflightScreenCaptureAccess() { return "Needs Screen Recording permission (System Settings › Privacy & Security)" }
    if IsSecureEventInputEnabled() { return "Paused: password entry" }
    if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, settings.neverApps.contains(front) {
      return "Paused: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? front) is in front"
    }
    return nil
  }

  private func tick() async {
    if let reason = pauseReason() {
      if !paused { for w in workers.values { w.reset(keepCache: true) } }
      paused = true
      setStatus(reason)
      return
    }
    paused = false
    do {
      if content == nil || Date().timeIntervalSince(contentAt) > 5 {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        contentAt = Date()
        syncWorkers()
      }
      guard let content else { return }
      let excluded = content.applications.filter { $0.processID == getpid() || settings.neverApps.contains($0.bundleIdentifier) }
      let judge = Judge(client: DecisionsClient(key: key, url: decisionsURL), bubbles: settings.bubbles,
                        threshold: settings.threshold, mode: settings.mode)
      let useSAM = settings.tighterShapes && (!falKey.isEmpty || samURL != SAMClient.defaultURL)
      let sam = useSAM ? SAMClient(key: falKey, url: samURL) : nil
      for display in content.displays {
        guard let worker = workers[display.displayID] else { continue }
        worker.sam = sam
        worker.bubbles = settings.bubbles
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width   // points: one pixel per point
        config.height = display.height
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        worker.handle(image, judge: judge)
      }
      let masked = workers.values.reduce(0) { $0 + $1.tracker.masked.count }
      setStatus(masked > 0 ? "Watching · \(masked) cell\(masked == 1 ? "" : "s") hidden" : "Watching")
    } catch {
      setStatus("Capture failed: \(error.localizedDescription)")
      content = nil
    }
  }

  private func syncWorkers() {
    guard let content else { return }
    let live = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
    for (id, w) in workers where live[id] == nil || live[id]!.frame != w.frame || w.spec != settings.grid {
      w.reset(keepCache: false)
      workers.removeValue(forKey: id)
    }
    for (id, d) in live where workers[id] == nil {
      let w = DisplayWorker(displayID: id, frame: d.frame, spec: settings.grid)
      w.onJudged = { [weak self] r, cells in self?.judged(r, cells: cells, display: id) }
      workers[id] = w
    }
  }

  private func judged(_ r: JudgeResult, cells: Int, display: CGDirectDisplayID) {
    let hidden = r.verdicts.values.filter(\.hide)
    let reasons = Set(hidden.flatMap(\.reasons)).sorted()
    lastPass = String(format: "Last pass: %d cells, %d requests, %.2f s%@", cells, r.requests, r.seconds,
                      hidden.isEmpty ? "" : " · \(hidden.count) hidden")
    Log.write(String(format: "display %u %@: %d cells, %d requests, %.2f s, %d hidden %@%@", display, settings.mode.rawValue,
                     cells, r.requests, r.seconds, hidden.count, reasons.description,
                     r.errors.isEmpty ? "" : " errors: \(r.errors.prefix(3).joined(separator: " | "))"))
    if !r.errors.isEmpty, r.verdicts.isEmpty { setStatus("Model error: \(r.errors[0].prefix(120))") }
  }

  private func setStatus(_ s: String) {
    status = s
    statusItem.button?.appearsDisabled = paused
  }

  private func changed(keepCache: Bool = false) {
    settings.save()
    for w in workers.values { w.reset(keepCache: keepCache) }
    syncWorkers()
    Log.write("settings: mode \(settings.mode.rawValue), grid \(settings.grid.cols)x\(settings.grid.rows), threshold \(settings.threshold), bubbles \(settings.bubbles.map(\.label))")
  }

  // MARK: menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    menu.addItem(withTitle: "Signal & Noise for macOS (experimental)", action: nil, keyEquivalent: "").isEnabled = false
    menu.addItem(withTitle: status, action: nil, keyEquivalent: "").isEnabled = false
    if !lastPass.isEmpty { menu.addItem(withTitle: lastPass, action: nil, keyEquivalent: "").isEnabled = false }
    menu.addItem(.separator())
    item(menu, settings.enabled ? "Turn off" : "Turn on") { $0.settings.enabled.toggle(); $0.changed(keepCache: true) }

    let hide = NSMenu()
    for b in Bubbles.common {
      let i = item(hide, b.label) { c in
        if c.settings.picked.contains(b.id) { c.settings.picked.removeAll { $0 == b.id } } else { c.settings.picked.append(b.id) }
        c.changed()
      }
      i.state = settings.picked.contains(b.id) ? .on : .off
    }
    hide.addItem(.separator())
    for text in settings.customs {
      item(hide, "“\(text)” (click to remove)") { c in c.settings.customs.removeAll { $0 == text }; c.changed() }.state = .on
    }
    item(hide, "Add your own…") { c in
      if let text = c.prompt("Hide anything showing…", info: "Describe it in plain words, e.g. “spiders” or “anything about the Oilers”.", secure: false), !text.isEmpty {
        c.settings.customs.append(text); c.changed()
      }
    }
    submenu(menu, "Hide", hide)

    let strict = NSMenu()
    for t in [0.5, 0.6, 0.7, 0.8, 0.9] {
      item(strict, "Mask at \(Int(t * 100))% sure") { c in c.settings.threshold = t; c.changed() }.state = settings.threshold == t ? .on : .off
    }
    submenu(menu, "Strictness", strict)

    let finding = NSMenu()
    item(finding, "Tiles: each cell with context, one request per cell") { c in c.settings.mode = .tiles; c.changed() }.state = settings.mode == .tiles ? .on : .off
    item(finding, "Grid: whole screen, one question per cell") { c in c.settings.mode = .grid; c.changed() }.state = settings.mode == .grid ? .on : .off
    finding.addItem(.separator())
    for g in [GridSpec(cols: 6, rows: 4), GridSpec(cols: 8, rows: 5), GridSpec(cols: 12, rows: 8)] {
      item(finding, "\(g.cols) × \(g.rows) cells") { c in c.settings.grid = g; c.changed() }.state = settings.grid == g ? .on : .off
    }
    finding.addItem(.separator())
    let samTitle = falKey.isEmpty && samURL == SAMClient.defaultURL
      ? "Tighter shapes with SAM (set a fal.ai key first)" : "Tighter shapes with SAM (fal.ai, $0.005 per mask)"
    item(finding, samTitle) { c in c.settings.tighterShapes.toggle(); c.changed(keepCache: true) }.state = settings.tighterShapes ? .on : .off
    submenu(menu, "Finding regions", finding)

    menu.addItem(.separator())
    item(menu, key.isEmpty ? "Set OpenAI key…" : "Change OpenAI key…") { c in
      if let k = c.prompt("OpenAI API key", info: "Stored in your login keychain. Used only for api.openai.com/v1/decisions.", secure: true) {
        KeyStore.save(k); c.key = KeyStore.load(); c.changed(keepCache: true)
      }
    }
    item(menu, falKey.isEmpty ? "Set fal.ai key (for SAM)…" : "Change fal.ai key…") { c in
      if let k = c.prompt("fal.ai API key", info: "Stored in your login keychain. Used only for fal.run/fal-ai/sam-3/image, to reshape masks.", secure: true) {
        KeyStore.save(k, account: "fal"); c.falKey = KeyStore.load("fal"); c.changed(keepCache: true)
      }
    }
    item(menu, "Open log") { _ in NSWorkspace.shared.open(Log.url) }
    item(menu, "Quit") { _ in NSApp.terminate(nil) }
  }

  @discardableResult
  private func item(_ menu: NSMenu, _ title: String, _ run: @escaping (AppController) -> Void) -> NSMenuItem {
    let i = ClosureItem(title: title) { [weak self] in if let self { run(self) } }
    menu.addItem(i)
    return i
  }

  private func submenu(_ menu: NSMenu, _ title: String, _ sub: NSMenu) {
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.submenu = sub
    menu.addItem(i)
  }

  private func prompt(_ title: String, info: String, secure: Bool) -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = info
    let field = secure ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)) : NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

final class ClosureItem: NSMenuItem {
  private let run: () -> Void
  init(title: String, run: @escaping () -> Void) {
    self.run = run
    super.init(title: title, action: #selector(fire), keyEquivalent: "")
    target = self
  }
  required init(coder: NSCoder) { fatalError() }
  @objc private func fire() { run() }
}

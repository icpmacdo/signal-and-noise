// One mask: a small borderless panel above every app, blurring what's under it. Only the masks
// take the mouse, so the rest of the screen works as usual. Hover (after a short delay) peeks
// through; a click reveals it for good, until that content changes.
import AppKit

final class MaskPanel: NSPanel {
  private let maskView: MaskView

  init(frame: NSRect, label: String, onReveal: @escaping () -> Void) {
    maskView = MaskView(frame: NSRect(origin: .zero, size: frame.size), onReveal: onReveal)
    super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    becomesKeyOnlyIfNeeded = true
    contentView = maskView
    setLabel(label)
    alphaValue = 0
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  func setLabel(_ text: String) { maskView.label.stringValue = text }

  func fadeIn() {
    orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { $0.duration = 0.3; animator().alphaValue = 1 }
  }

  func fadeOutAndClose(_ duration: TimeInterval = 0.2) {
    NSAnimationContext.runAnimationGroup({ $0.duration = duration; animator().alphaValue = 0 }) { [weak self] in
      self?.orderOut(nil)
      self?.close()
    }
  }
}

final class MaskView: NSView {
  let blur = NSVisualEffectView()
  let tint = NSView()
  let label = NSTextField(labelWithString: "")
  let hint = NSTextField(labelWithString: "hover to peek · click to show")
  private let onReveal: () -> Void
  private var peekTimer: Timer?

  init(frame: NSRect, onReveal: @escaping () -> Void) {
    self.onReveal = onReveal
    super.init(frame: frame)
    wantsLayer = true
    // Nearly invisible fill so the panel still catches the mouse while peeking.
    layer?.backgroundColor = NSColor(white: 0, alpha: 0.004).cgColor
    layer?.cornerRadius = 10
    layer?.masksToBounds = true

    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    tint.wantsLayer = true
    tint.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.45).cgColor

    label.font = .systemFont(ofSize: 13, weight: .semibold)
    label.textColor = .white
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail
    hint.font = .systemFont(ofSize: 11)
    hint.textColor = NSColor(white: 1, alpha: 0.7)
    hint.alignment = .center

    for v in [blur, tint] { v.frame = bounds; v.autoresizingMask = [.width, .height]; addSubview(v) }
    let stack = NSStackView(views: [label, hint])
    stack.orientation = .vertical
    stack.spacing = 2
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
    ])
    hint.isHidden = frame.height < 70
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseEntered(with event: NSEvent) {
    peekTimer?.invalidate()
    peekTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in self?.setPeek(true) }
  }

  override func mouseExited(with event: NSEvent) {
    peekTimer?.invalidate()
    setPeek(false)
  }

  override func mouseDown(with event: NSEvent) {
    peekTimer?.invalidate()
    onReveal()
  }

  private func setPeek(_ on: Bool) {
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.2
      for v in [blur, tint, label, hint] as [NSView] { v.animator().alphaValue = on ? 0 : 1 }
    }
  }
}

// Signal & Noise for macOS (experimental). A menu-bar app that watches the whole screen and blurs
// the parts that match your bubbles, judged from pixels by OpenAI's Decisions API.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
MainActor.assumeIsolated {
  let controller = AppController()
  app.delegate = controller
  app.run()
}

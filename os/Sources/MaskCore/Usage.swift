// What the models cost while the app runs: requests, tokens and dollars per model, for this
// session and for today, plus the last minute for a rate. Every client that calls a model
// (Decisions on any route, SAM on fal.ai) reports here after each request.
//
// Cost is what the response says when it says (OpenRouter's `usage.cost`), otherwise tokens times
// the list price below. Decisions-style models bill input only. Prices as listed on 2026-10-18:
// gpt-6-luna $0.10 per million input tokens (OpenAI); Jev 1.13/1.14 $0.042 (docs.typesafe.ai/models;
// assumed the same on OpenRouter); SAM 3 on fal.ai $0.005 per call.
import Foundation

public enum Pricing {
  /// Dollars per million input tokens, or per call.
  public enum Price: Equatable, Sendable {
    case perMillionInput(Double)
    case perCall(Double)
  }

  public static let table: [String: Price] = [
    "gpt-6-luna": .perMillionInput(0.10),
    "openai/gpt-6-luna-decisions": .perMillionInput(0.10),
    "jev-1.14.0": .perMillionInput(0.042),
    "jev-1.13.0": .perMillionInput(0.042),
    "jev-preview": .perMillionInput(0.042),
    "typesafe/jev-1.14": .perMillionInput(0.042),
    "fal-ai/sam-3/image": .perCall(0.005),
  ]

  /// Estimated cost of one request; nil when the model isn't in the table.
  public static func cost(model: String, inputTokens: Int) -> Double? {
    switch table[model] {
    case .perMillionInput(let p): return Double(inputTokens) * p / 1_000_000
    case .perCall(let p): return p
    case nil: return nil
    }
  }

  /// A short name for the widget.
  public static func shortName(_ model: String) -> String {
    if model.contains("luna") { return "luna" }
    if model.contains("jev") { return model.hasPrefix("typesafe/") ? "Jev (OpenRouter)" : "Jev" }
    if model.contains("sam") { return "SAM" }
    return model
  }
}

public final class UsageMeter: @unchecked Sendable {
  public struct Line: Codable, Equatable, Sendable {
    public var requests = 0
    public var failures = 0
    public var inputTokens = 0
    public var outputTokens = 0
    /// Dollars: reported where the API said, estimated otherwise.
    public var cost = 0.0
    /// Requests whose cost was estimated from list prices, and ones with no price at all.
    public var estimated = 0
    public var unpriced = 0
    public init() {}

    mutating func add(_ o: Line) {
      requests += o.requests; failures += o.failures; inputTokens += o.inputTokens; outputTokens += o.outputTokens
      cost += o.cost; estimated += o.estimated; unpriced += o.unpriced
    }
  }

  public struct Snapshot: Sendable {
    public var session: [String: Line]
    public var today: [String: Line]
    public var day: String
    public var started: Date
    /// The last 60 seconds, all models.
    public var lastMinute: Line

    public var sessionTotal: Line { session.values.reduce(into: Line()) { $0.add($1) } }
    public var todayTotal: Line { today.values.reduce(into: Line()) { $0.add($1) } }
  }

  private let lock = NSLock()
  private var session: [String: Line] = [:]
  private var today: [String: Line] = [:]
  private var day: String
  private let started: Date
  private var recent: [(Date, Line)] = []
  private let now: @Sendable () -> Date
  /// Bumped on every record, so a caller can tell whether there's anything new to save.
  public private(set) var version = 0

  public init(now: @escaping @Sendable () -> Date = Date.init) {
    self.now = now
    started = now()
    day = UsageMeter.dayKey(now())
  }

  public static func dayKey(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }

  /// Bring back today's totals saved by an earlier run (ignored if they're from another day).
  public func restore(day saved: String, today saved2: [String: Line]) {
    lock.lock(); defer { lock.unlock() }
    if saved == day { today = saved2 }
  }

  /// One request to `model`. `reportedCost`: what the response said it cost, if it did.
  public func record(model: String, inputTokens: Int = 0, outputTokens: Int = 0, reportedCost: Double? = nil, failed: Bool = false) {
    var line = Line()
    line.requests = 1
    line.failures = failed ? 1 : 0
    line.inputTokens = inputTokens
    line.outputTokens = outputTokens
    if let reportedCost {
      line.cost = reportedCost
    } else if failed {
      line.cost = 0
    } else if let c = Pricing.cost(model: model, inputTokens: inputTokens) {
      line.cost = c
      line.estimated = 1
    } else {
      line.unpriced = 1
    }
    let t = now()
    lock.lock(); defer { lock.unlock() }
    let d = UsageMeter.dayKey(t)
    if d != day { day = d; today = [:] }
    session[model, default: Line()].add(line)
    today[model, default: Line()].add(line)
    recent.append((t, line))
    recent.removeAll { t.timeIntervalSince($0.0) > 60 }
    version += 1
  }

  public func snapshot() -> Snapshot {
    let t = now()
    lock.lock(); defer { lock.unlock() }
    let minute = recent.filter { t.timeIntervalSince($0.0) <= 60 }.reduce(into: Line()) { $0.add($1.1) }
    return Snapshot(session: session, today: UsageMeter.dayKey(t) == day ? today : [:], day: UsageMeter.dayKey(t), started: started, lastMinute: minute)
  }

  /// `usage` from a Decisions, OpenRouter or TypeSafe response: input/output tokens under either
  /// naming, and OpenRouter's `cost` when present.
  public static func parse(_ data: Data) -> (input: Int, output: Int, cost: Double?) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let u = json["usage"] as? [String: Any] else { return (0, 0, nil) }
    func int(_ keys: [String]) -> Int { keys.lazy.compactMap { (u[$0] as? NSNumber)?.intValue }.first ?? 0 }
    return (int(["input_tokens", "prompt_tokens"]), int(["output_tokens", "completion_tokens"]), (u["cost"] as? NSNumber)?.doubleValue)
  }
}

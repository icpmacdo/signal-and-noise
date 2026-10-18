// OpenAI's Decisions API (gpt-6-luna): shared input (text plus one inline image) and typed
// questions; answers come back by question name. Images must be data: URLs. Billing is input
// tokens only, so many questions about one image cost the same as one.
//
// Two routes to the same model, picked by the key:
//  - OpenAI direct (POST api.openai.com/v1/decisions): `input` messages, `questions` array,
//    yes/no questions are `predicate` with a `probability`.
//  - OpenRouter (sk-or-… keys; POST openrouter.ai/api/alpha/decisions, model
//    openai/gpt-6-luna-decisions): `state` array of {type:text} / {type:image_url} items,
//    `questions` keyed by name, yes/no questions are `noul` answered with a `noul` value 0-1,
//    choice criteria and probabilities are objects. (Images anywhere else in `state` are read as
//    text, not seen.)
//
// The OpenRouter endpoint also serves TypeSafe's Jev (typesafe/jev-1.14), which adds `box`
// questions: "where is X?" answered with one box as fractions of the image (top, bottom, left,
// right from the top-left) and a confidence. Box never says "not found", so ask a noul about the
// same thing in the request. Only Jev 1.14+ answers box questions; gpt-6-luna and Jev 1.13 reject
// them. Images and Box are a TypeSafe preview (docs.typesafe.ai/primitives/box, 2026-10-18).
//
// A third route goes to TypeSafe directly (POST api.typesafe.ai/v1/systemone, jev-1.14.0, a
// TypeSafe key): `state` is a map whose `screen` names an entry in `assets` (base64, no data:
// prefix), questions and answers are keyed as on OpenRouter, and every request with an image
// carries `TypeSafe-Danger-Zone-Images: true`. Jev takes images 280 to 1568 px a side, so images
// are refitted (scaled, padded white at the right or bottom) before they go.
import CoreGraphics
import Foundation
import ImageIO

public enum Question: Sendable, Equatable {
  case predicate(name: String, instructions: String)
  case choice(name: String, instructions: String, choices: [(value: String, description: String)])
  /// "Where is …?": one box. Jev 1.14+ only.
  case box(name: String, instructions: String)

  public var name: String {
    switch self {
    case .predicate(let name, _), .choice(let name, _, _), .box(let name, _): return name
    }
  }

  var json: [String: Any] {
    switch self {
    case .predicate(let name, let instructions):
      return ["type": "predicate", "name": name, "instructions": instructions]
    case .choice(let name, let instructions, let choices):
      return ["type": "choice", "name": name, "instructions": instructions,
              "choices": choices.map { ["value": $0.value, "description": $0.description] }]
    case .box(let name, let instructions):
      return ["type": "box", "name": name, "instructions": instructions]
    }
  }

  public static func == (a: Question, b: Question) -> Bool {
    NSDictionary(dictionary: a.json).isEqual(to: b.json)
  }
}

public struct Answer: Sendable, Equatable {
  public let name: String
  /// Predicate: P(true). Choice: absent.
  public let probability: Double?
  /// Choice: the picked value and the distribution over values.
  public let choice: String?
  public let probabilities: [String: Double]
  /// Box: the box as fractions of the image (top-left origin), and how sure the model is.
  public let box: CGRect?
  public let confidence: Double?

  public init(name: String, probability: Double? = nil, choice: String? = nil, probabilities: [String: Double] = [:],
              box: CGRect? = nil, confidence: Double? = nil) {
    self.name = name
    self.probability = probability
    self.choice = choice
    self.probabilities = probabilities
    self.box = box
    self.confidence = confidence
  }
}

public struct DecisionsError: Error, CustomStringConvertible {
  public let description: String
}

public enum Route: String, Sendable {
  case openai, openrouter, typesafe

  /// OpenRouter keys start with sk-or-.
  public static func forKey(_ key: String) -> Route { key.hasPrefix("sk-or-") ? .openrouter : .openai }

  public var url: URL {
    switch self {
    case .openai: return URL(string: "https://api.openai.com/v1/decisions")!
    case .openrouter: return URL(string: "https://openrouter.ai/api/alpha/decisions")!
    case .typesafe: return URL(string: "https://api.typesafe.ai/v1/systemone")!
    }
  }

  /// Pinned, as the extension pins jev-1.13.0, so a model update can't silently move the masks.
  public var model: String {
    switch self {
    case .openai: return "gpt-6-luna"
    case .openrouter: return "openai/gpt-6-luna-decisions"
    case .typesafe: return "jev-1.14.0"
    }
  }

  /// Routes that answer box questions, and the model that does on each.
  public var answersBoxes: Bool { self != .openai }
  public var boxModel: String { self == .typesafe ? model : Route.boxModel }

  /// The model that answers box questions on OpenRouter.
  public static let boxModel = "typesafe/jev-1.14"
}

public enum Decisions {
  public static let defaultURL = Route.openai.url
  public static let model = Route.openai.model

  public static func body(text: String, imageDataURL: String?, questions: [Question], model: String = model,
                          route: Route = .openai) -> [String: Any] {
    if route == .typesafe {
      var state: [String: Any] = ["about": text]
      var assets: [String: Any] = [:]
      if let imageDataURL, let comma = imageDataURL.firstIndex(of: ",") {
        let format = imageDataURL.hasPrefix("data:image/png") ? "png" : "jpg"
        assets["screen-image"] = ["type": "image", "format": format, "data_base64": String(imageDataURL[imageDataURL.index(after: comma)...])]
        state["screen"] = "screen-image"
      }
      var body: [String: Any] = ["model": model, "state": state, "questions": keyedQuestions(questions)]
      if !assets.isEmpty { body["assets"] = assets }
      return body
    }
    if route == .openrouter {
      var state: [[String: Any]] = [["type": "text", "text": text]]
      if let imageDataURL { state.append(["type": "image_url", "image_url": ["url": imageDataURL]]) }
      return ["model": model, "state": state, "questions": keyedQuestions(questions)]
    }
    var content: [[String: Any]] = [["type": "input_text", "text": text]]
    if let imageDataURL { content.append(["type": "input_image", "image_url": imageDataURL]) }
    return ["model": model, "input": [["role": "user", "content": content]], "questions": questions.map(\.json)]
  }

  /// Questions keyed by name, yes/no as `noul` (OpenRouter and TypeSafe).
  static func keyedQuestions(_ questions: [Question]) -> [String: Any] {
    var qs: [String: Any] = [:]
    for q in questions {
      switch q {
      case .predicate(let name, let instructions):
        qs[name] = ["type": "noul", "instructions": instructions]
      case .choice(let name, let instructions, let choices):
        qs[name] = ["type": "choice", "instructions": instructions,
                    "criteria": Dictionary(choices.map { ($0.value, $0.description) }, uniquingKeysWith: { a, _ in a })]
      case .box(let name, let instructions):
        qs[name] = ["type": "box", "instructions": instructions]
      }
    }
    return qs
  }

  /// A data: URL image refitted to Jev's size limits, as a JPEG data: URL. Unreadable: unchanged.
  public static func fittedForJev(_ dataURL: String) -> String {
    guard let comma = dataURL.firstIndex(of: ","), let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
          let src = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return dataURL }
    guard image.width < 280 || image.height < 280 || image.width > 1568 || image.height > 1568 else { return dataURL }
    guard let fitted = Imaging.fitForJev(image), let url = Imaging.jpegDataURL(fitted.image, quality: 0.85) else { return dataURL }
    return url
  }

  /// Answers by question name. Refusals and unknown answer types are dropped: no answer, no mask.
  public static func parse(_ data: Data) throws -> [String: Answer] {
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    if let keyed = json?["answers"] as? [String: [String: Any]] { return parseKeyed(keyed) }
    guard let answers = json?["answers"] as? [[String: Any]] else {
      throw DecisionsError(description: "no answers in response: \(String(decoding: data.prefix(300), as: UTF8.self))")
    }
    var out: [String: Answer] = [:]
    for a in answers {
      guard let name = a["name"] as? String, let type = a["type"] as? String else { continue }
      switch type {
      case "predicate":
        guard let p = (a["probability"] as? NSNumber)?.doubleValue else { continue }
        out[name] = Answer(name: name, probability: p, choice: nil, probabilities: [:])
      case "choice":
        var probs: [String: Double] = [:]
        for entry in a["probabilities"] as? [[String: Any]] ?? [] {
          if let v = entry["value"] as? String, let p = (entry["probability"] as? NSNumber)?.doubleValue { probs[v] = p }
        }
        out[name] = Answer(name: name, probability: nil, choice: a["choice"] as? String, probabilities: probs)
      case "box":
        if let b = box(a) { out[name] = b.with(name) }
      default:
        continue
      }
    }
    return out
  }

  /// A box answer's edges as a unit rect; nil when an edge is missing or the box is empty.
  static func box(_ a: [String: Any]) -> Answer? {
    guard let b = a["box"] as? [String: Any] else { return nil }
    let e = ["top", "bottom", "left", "right"].compactMap { (b[$0] as? NSNumber)?.doubleValue }
    guard e.count == 4 else { return nil }
    let (top, bottom) = (max(0, min(1, e[0])), max(0, min(1, e[1])))
    let (left, right) = (max(0, min(1, e[2])), max(0, min(1, e[3])))
    guard right > left, bottom > top else { return nil }
    return Answer(name: "", box: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                  confidence: (a["confidence"] as? NSNumber)?.doubleValue)
  }

  /// OpenRouter's shape: answers keyed by name; `noul` carries P(yes), choice probabilities are
  /// an object.
  static func parseKeyed(_ answers: [String: [String: Any]]) -> [String: Answer] {
    var out: [String: Answer] = [:]
    for (name, a) in answers {
      switch a["type"] as? String {
      case "noul", "predicate":
        guard let p = ((a["noul"] ?? a["probability"]) as? NSNumber)?.doubleValue else { continue }
        out[name] = Answer(name: name, probability: p, choice: nil, probabilities: [:])
      case "choice":
        let probs = (a["probabilities"] as? [String: NSNumber])?.mapValues(\.doubleValue) ?? [:]
        out[name] = Answer(name: name, probability: nil, choice: a["choice"] as? String, probabilities: probs)
      case "box":
        if let b = box(a) { out[name] = b.with(name) }
      default:
        continue
      }
    }
    return out
  }
}

extension Answer {
  func with(_ name: String) -> Answer {
    Answer(name: name, probability: probability, choice: choice, probabilities: probabilities, box: box, confidence: confidence)
  }
}

public final class DecisionsClient: @unchecked Sendable {
  public let url: URL
  public let key: String
  public let model: String
  public let route: Route
  let session: URLSession
  let timeout: TimeInterval
  /// Told about every request: tokens, cost, failures.
  public let meter: UsageMeter?

  /// The route (and with it the default URL and model name) follows the key unless given. `model`
  /// overrides the route's model, e.g. typesafe/jev-1.14 on OpenRouter for box questions.
  public init(key: String, url: URL? = nil, route: Route? = nil, model: String? = nil, session: URLSession = .shared,
              timeout: TimeInterval = 10, meter: UsageMeter? = nil) {
    self.meter = meter
    let route = route ?? Route.forKey(key)
    self.key = key
    self.route = route
    self.url = url ?? route.url
    self.model = model ?? route.model
    self.session = session
    self.timeout = timeout
  }

  public func ask(text: String, imageDataURL: String?, questions: [Question]) async throws -> [String: Answer] {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    var image = imageDataURL
    if route == .typesafe, let url = imageDataURL {
      req.setValue("true", forHTTPHeaderField: "TypeSafe-Danger-Zone-Images")
      image = Decisions.fittedForJev(url)
    }
    req.httpBody = try JSONSerialization.data(withJSONObject: Decisions.body(text: text, imageDataURL: image, questions: questions, model: model, route: route))
    let data: Data, resp: URLResponse
    do { (data, resp) = try await session.data(for: req) } catch {
      meter?.record(model: model, failed: true)
      throw error
    }
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    let usage = UsageMeter.parse(data)
    meter?.record(model: model, inputTokens: usage.input, outputTokens: usage.output, reportedCost: usage.cost,
                  failed: !(200..<300).contains(status))
    guard (200..<300).contains(status) else {
      throw DecisionsError(description: "HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
    }
    return try Decisions.parse(data)
  }
}

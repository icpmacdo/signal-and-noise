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
import Foundation

public enum Question: Sendable, Equatable {
  case predicate(name: String, instructions: String)
  case choice(name: String, instructions: String, choices: [(value: String, description: String)])

  public var name: String {
    switch self {
    case .predicate(let name, _), .choice(let name, _, _): return name
    }
  }

  var json: [String: Any] {
    switch self {
    case .predicate(let name, let instructions):
      return ["type": "predicate", "name": name, "instructions": instructions]
    case .choice(let name, let instructions, let choices):
      return ["type": "choice", "name": name, "instructions": instructions,
              "choices": choices.map { ["value": $0.value, "description": $0.description] }]
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
}

public struct DecisionsError: Error, CustomStringConvertible {
  public let description: String
}

public enum Route: String, Sendable {
  case openai, openrouter

  /// OpenRouter keys start with sk-or-.
  public static func forKey(_ key: String) -> Route { key.hasPrefix("sk-or-") ? .openrouter : .openai }

  public var url: URL {
    URL(string: self == .openai ? "https://api.openai.com/v1/decisions" : "https://openrouter.ai/api/alpha/decisions")!
  }

  public var model: String { self == .openai ? "gpt-6-luna" : "openai/gpt-6-luna-decisions" }
}

public enum Decisions {
  public static let defaultURL = Route.openai.url
  public static let model = Route.openai.model

  public static func body(text: String, imageDataURL: String?, questions: [Question], model: String = model,
                          route: Route = .openai) -> [String: Any] {
    if route == .openrouter {
      var state: [[String: Any]] = [["type": "text", "text": text]]
      if let imageDataURL { state.append(["type": "image_url", "image_url": ["url": imageDataURL]]) }
      var qs: [String: Any] = [:]
      for q in questions {
        switch q {
        case .predicate(let name, let instructions):
          qs[name] = ["type": "noul", "instructions": instructions]
        case .choice(let name, let instructions, let choices):
          qs[name] = ["type": "choice", "instructions": instructions,
                      "criteria": Dictionary(choices.map { ($0.value, $0.description) }, uniquingKeysWith: { a, _ in a })]
        }
      }
      return ["model": model, "state": state, "questions": qs]
    }
    var content: [[String: Any]] = [["type": "input_text", "text": text]]
    if let imageDataURL { content.append(["type": "input_image", "image_url": imageDataURL]) }
    return ["model": model, "input": [["role": "user", "content": content]], "questions": questions.map(\.json)]
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
      default:
        continue
      }
    }
    return out
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
      default:
        continue
      }
    }
    return out
  }
}

public final class DecisionsClient: @unchecked Sendable {
  public let url: URL
  public let key: String
  public let model: String
  public let route: Route
  let session: URLSession
  let timeout: TimeInterval

  /// The route (and with it the default URL and model name) follows the key unless given.
  public init(key: String, url: URL? = nil, route: Route? = nil, session: URLSession = .shared, timeout: TimeInterval = 10) {
    let route = route ?? Route.forKey(key)
    self.key = key
    self.route = route
    self.url = url ?? route.url
    self.model = route.model
    self.session = session
    self.timeout = timeout
  }

  public func ask(text: String, imageDataURL: String?, questions: [Question]) async throws -> [String: Answer] {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    req.httpBody = try JSONSerialization.data(withJSONObject: Decisions.body(text: text, imageDataURL: imageDataURL, questions: questions, model: model, route: route))
    let (data, resp) = try await session.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw DecisionsError(description: "HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
    }
    return try Decisions.parse(data)
  }
}

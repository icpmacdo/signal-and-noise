// OpenAI's Decisions API (POST /v1/decisions, gpt-6-luna): shared input (text plus one inline
// image) and a list of typed questions; answers come back by question name. Images must be data:
// URLs. Billing is input tokens only, so many questions about one image cost the same as one.
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

public enum Decisions {
  public static let defaultURL = URL(string: "https://api.openai.com/v1/decisions")!
  public static let model = "gpt-6-luna"

  public static func body(text: String, imageDataURL: String?, questions: [Question], model: String = model) -> [String: Any] {
    var content: [[String: Any]] = [["type": "input_text", "text": text]]
    if let imageDataURL { content.append(["type": "input_image", "image_url": imageDataURL]) }
    return ["model": model, "input": [["role": "user", "content": content]], "questions": questions.map(\.json)]
  }

  /// Answers by question name. Refusals and unknown answer types are dropped: no answer, no mask.
  public static func parse(_ data: Data) throws -> [String: Answer] {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let answers = json["answers"] as? [[String: Any]] else {
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
}

public final class DecisionsClient: @unchecked Sendable {
  public let url: URL
  public let key: String
  public let model: String
  let session: URLSession
  let timeout: TimeInterval

  public init(key: String, url: URL = Decisions.defaultURL, model: String = Decisions.model,
              session: URLSession = .shared, timeout: TimeInterval = 10) {
    self.key = key
    self.url = url
    self.model = model
    self.session = session
    self.timeout = timeout
  }

  public func ask(text: String, imageDataURL: String?, questions: [Question]) async throws -> [String: Answer] {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    req.httpBody = try JSONSerialization.data(withJSONObject: Decisions.body(text: text, imageDataURL: imageDataURL, questions: questions, model: model))
    let (data, resp) = try await session.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw DecisionsError(description: "HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
    }
    return try Decisions.parse(data)
  }
}

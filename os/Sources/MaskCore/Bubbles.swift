// What can be masked. The common ones are tuned for a whole screen rather than an X timeline:
// each description finishes the sentence "Does the outlined region show …?".
import Foundation

public struct Bubble: Codable, Hashable, Sendable {
  public let id: String
  public let label: String
  public let description: String
  /// A short noun phrase SAM can segment ("advertisement"), for bubbles that are about how
  /// something looks. Nil for bubbles about what text says: those keep their grid masks.
  public let segment: String?

  public init(id: String, label: String, description: String, segment: String? = nil) {
    self.id = id
    self.label = label
    self.description = description
    self.segment = segment
  }
}

public enum Bubbles {
  public static let common: [Bubble] = [
    Bubble(id: "ads", label: "Ads", description: "an advertisement, sponsored or promoted content, or a banner selling something", segment: "advertisement"),
    Bubble(id: "memes", label: "Memes", description: "a meme image, reaction picture or joke image format", segment: "meme image"),
    Bubble(id: "violence", label: "Graphic violence", description: "blood, injuries, gore or graphic violence", segment: "blood or injury"),
    Bubble(id: "nsfw", label: "Sexual content", description: "nudity or sexually suggestive imagery", segment: "person"),
    Bubble(id: "slop", label: "AI slop images", description: "a low-effort AI-generated picture", segment: "picture"),
    Bubble(id: "clickbait", label: "Clickbait", description: "a clickbait headline or thumbnail (shocked faces, giant arrows, 'you won't believe')", segment: "thumbnail"),
    Bubble(id: "rage", label: "Political rage bait", description: "political content written to make people angry"),
    Bubble(id: "crypto", label: "Crypto shilling", description: "promotion of crypto coins, tokens, airdrops or trading schemes"),
  ]

  public static let defaultPicked = ["ads"]

  /// A mute typed in plain words. Question names must be simple identifiers, so customs are numbered.
  public static func custom(_ text: String, index: Int) -> Bubble {
    Bubble(id: "c\(index)", label: text, description: text, segment: text)
  }

  /// The bubbles a set of settings asks about, in a stable order.
  public static func active(picked: [String], customs: [String]) -> [Bubble] {
    common.filter { picked.contains($0.id) } + customs.enumerated().map { custom($1, index: $0) }
  }
}

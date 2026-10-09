import CoreGraphics
import Foundation
import XCTest
@testable import MaskCore

final class DecisionsTests: XCTestCase {
  func testBodyHasTextImageAndQuestions() throws {
    let body = Decisions.body(text: "hi", imageDataURL: "data:image/jpeg;base64,AAA",
                              questions: [.predicate(name: "ads", instructions: "ad?")])
    XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
    let content = ((body["input"] as! [[String: Any]])[0]["content"]) as! [[String: Any]]
    XCTAssertEqual(content.map { $0["type"] as! String }, ["input_text", "input_image"])
    XCTAssertEqual(content[1]["image_url"] as? String, "data:image/jpeg;base64,AAA")
    let q = (body["questions"] as! [[String: Any]])[0]
    XCTAssertEqual(q["type"] as? String, "predicate")
    XCTAssertEqual(q["name"] as? String, "ads")
  }

  func testParsePredicateAndChoiceDropOthers() throws {
    let json = """
    {"answers":[{"type":"predicate","name":"ads","probability":0.92},
      {"type":"choice","name":"C2","choice":"memes","probabilities":[{"value":"keep","probability":0.2},{"value":"memes","probability":0.8}],"confidence":0.6},
      {"type":"refusal","name":"x"}]}
    """
    let a = try Decisions.parse(Data(json.utf8))
    XCTAssertEqual(a["ads"]?.probability, 0.92)
    XCTAssertEqual(a["C2"]?.choice, "memes")
    XCTAssertEqual(a["C2"]?.probabilities["memes"], 0.8)
    XCTAssertNil(a["x"])
  }
}

final class GridTests: XCTestCase {
  let spec = GridSpec(cols: 4, rows: 3)

  func testRectsTileTheImageExactly() {
    var area: CGFloat = 0
    for i in 0..<spec.count { area += spec.rect(i, width: 1001, height: 601).width * spec.rect(i, width: 1001, height: 601).height }
    XCTAssertEqual(area, 1001 * 601)
    XCTAssertEqual(spec.label(0), "A1")
    XCTAssertEqual(spec.label(6), "C2")
    XCTAssertEqual(GridSpec("8x5"), GridSpec(cols: 8, rows: 5))
    XCTAssertEqual(GridSpec.fitting(width: 3008, height: 1692), GridSpec(cols: 14, rows: 8))
  }

  func testMergeCoversExactlyTheMaskedCells() {
    // A 2x2 block plus a lone cell.
    let masked: Set<Int> = [0, 1, 4, 5, 11]
    let blocks = Merge.blocks(masked, spec: spec)
    XCTAssertEqual(blocks.count, 2)
    XCTAssertEqual(Set(blocks.flatMap { $0.cells(spec) }), masked)
    XCTAssertEqual(blocks.flatMap { $0.cells(spec) }.count, masked.count)
  }

  func testMergeLShapeStaysExact() {
    let masked: Set<Int> = [0, 1, 4]
    let blocks = Merge.blocks(masked, spec: spec)
    XCTAssertEqual(Set(blocks.flatMap { $0.cells(spec) }), masked)
  }

  func testHashSeesChangeButNotSameContent() {
    let a = TestImages.stripes(width: 200, height: 100, period: 10)
    let b = TestImages.stripes(width: 200, height: 100, period: 10)
    let c = TestImages.stripes(width: 200, height: 100, period: 33)
    let r = CGRect(x: 0, y: 0, width: 200, height: 100)
    let ha = RegionHash.of(a, rect: r)!, hb = RegionHash.of(b, rect: r)!, hc = RegionHash.of(c, rect: r)!
    XCTAssertEqual(ha.distance(hb), 0)
    XCTAssertGreaterThan(ha.distance(hc), 20)
  }
}

final class ImagingTests: XCTestCase {
  func testTileIsClampedAndScaled() {
    let img = TestImages.stripes(width: 1600, height: 1000, period: 20)
    let corner = Imaging.tile(img, cell: CGRect(x: 0, y: 0, width: 200, height: 200))!
    // 0.5 margin, but nothing exists left of or above the corner: 300x300.
    XCTAssertEqual(corner.width, 300)
    XCTAssertEqual(corner.height, 300)
    let big = Imaging.tile(img, cell: CGRect(x: 400, y: 300, width: 600, height: 400))!
    XCTAssertEqual(max(big.width, big.height), 512)
    XCTAssertTrue(Imaging.jpegDataURL(big)!.hasPrefix("data:image/jpeg;base64,"))
  }

  func testGridImageDraws() {
    let img = TestImages.stripes(width: 3000, height: 2000, period: 20)
    let g = Imaging.grid(img, spec: GridSpec(cols: 8, rows: 5))!
    XCTAssertEqual(g.width, 1600)
  }
}

final class TrackerTests: XCTestCase {
  let spec = GridSpec(cols: 2, rows: 1)
  func h(_ seed: UInt64) -> RegionHash { RegionHash(bits: [seed &* 0x9E3779B97F4A7C15, ~seed, seed << 7, seed ^ 0xFFFF0000FFFF]) }
  let ad = Verdict(hide: true, reasons: ["Ads"], scores: ["ads": 0.9])
  let fine = Verdict(hide: false, reasons: [], scores: ["ads": 0.1])

  func testJudgesAfterSettlingThenMasks() {
    let t = Tracker(spec: spec, movementCells: 2)
    var s = t.observe([h(1), h(2)], judging: false) // first frame: everything is new
    XCTAssertEqual(s.toJudge, [])
    s = t.observe([h(1), h(2)], judging: false)    // held still: ask
    XCTAssertEqual(s.toJudge, [0, 1])
    XCTAssertTrue(t.record([0: ad, 1: fine], judgedHashes: s.judgedHashes))
    XCTAssertEqual(Array(t.masked.keys), [0])
  }

  func testMovementDropsMaskAndCacheBringsItBack() {
    let t = Tracker(spec: spec, movementCells: 2)
    _ = t.observe([h(1), h(2)], judging: false)
    let s = t.observe([h(1), h(2)], judging: false)
    t.record([0: ad, 1: fine], judgedHashes: s.judgedHashes)
    let moved = t.observe([h(3), h(1)], judging: false) // the ad slid into cell 1
    XCTAssertTrue(moved.masksChanged)
    XCTAssertTrue(t.masked.isEmpty)
    let settled = t.observe([h(3), h(1)], judging: false)
    XCTAssertEqual(settled.toJudge, [0])                 // only the unseen content goes out
    XCTAssertEqual(settled.fromCache, 1)
    XCTAssertEqual(Array(t.masked.keys), [1])            // the ad is masked again without a call
  }

  func testLateVerdictForChangedCellIsIgnored() {
    let t = Tracker(spec: spec, movementCells: 2)
    _ = t.observe([h(1), h(2)], judging: false)
    let s = t.observe([h(1), h(2)], judging: false)
    _ = t.observe([h(5), h(2)], judging: true)            // cell 0 changed while the request was out
    XCTAssertFalse(t.record([0: ad], judgedHashes: s.judgedHashes))
    XCTAssertTrue(t.masked.isEmpty)
  }

  func testRevealHoldsUntilContentChanges() {
    let t = Tracker(spec: spec, movementCells: 2)
    _ = t.observe([h(1), h(2)], judging: false)
    let s = t.observe([h(1), h(2)], judging: false)
    t.record([0: ad], judgedHashes: s.judgedHashes)
    t.reveal([0])
    XCTAssertTrue(t.masked.isEmpty)
    _ = t.observe([h(2), h(1)], judging: false)
    _ = t.observe([h(1), h(2)], judging: false)            // the same ad back: still revealed
    _ = t.observe([h(1), h(2)], judging: false)
    XCTAssertTrue(t.masked.isEmpty)
  }
}

final class AnimationTests: XCTestCase {
  // Four cells in a row; a patch of 3+ changed cells is movement.
  let spec = GridSpec(cols: 4, rows: 1)
  func h(_ seed: UInt64) -> RegionHash { RegionHash(bits: [seed &* 0x9E3779B97F4A7C15, ~seed, seed << 7, seed ^ 0xFFFF0000FFFF]) }
  let ad = Verdict(hide: true, reasons: ["Ads"], scores: ["ads": 0.9])
  func tracker() -> Tracker { Tracker(spec: spec, movementCells: 3, animatedTicks: 3, rejudgeTicks: 10) }

  func masked(_ t: Tracker) -> [Int] { t.masked.keys.sorted() }

  /// Settle a first frame and mask cell 1.
  func settledWithAdAt1(_ t: Tracker) {
    _ = t.observe([h(1), h(2), h(3), h(4)], judging: false)
    let s = t.observe([h(1), h(2), h(3), h(4)], judging: false)
    t.record([1: ad], judgedHashes: s.judgedHashes)
  }

  func testPlayingVideoKeepsItsMask() {
    let t = tracker()
    settledWithAdAt1(t)
    for k in 0..<6 { _ = t.observe([h(1), h(100 + UInt64(k)), h(3), h(4)], judging: false) } // the ad plays
    XCTAssertEqual(masked(t), [1])
  }

  func testScrollDropsMasks() {
    let t = tracker()
    settledWithAdAt1(t)
    let s = t.observe([h(5), h(6), h(7), h(4)], judging: false) // three neighbours change at once
    XCTAssertTrue(s.masksChanged)
    XCTAssertEqual(s.moved, 3)
    XCTAssertEqual(masked(t), [])
  }

  func testAnimatedCellIsJudgedWithoutSettlingThenRateLimited() {
    let t = tracker()
    settledWithAdAt1(t)
    var judgedAt: [Int] = []
    for k in 0..<20 {
      let s = t.observe([h(1), h(2), h(200 + UInt64(k)), h(4)], judging: false) // cell 2 never holds still
      if s.toJudge.contains(2) { judgedAt.append(k) }
    }
    XCTAssertEqual(judgedAt.count, 2, "\(judgedAt)")             // once after it ran a while, once more after the rejudge gap
    XCTAssertGreaterThanOrEqual(judgedAt[1] - judgedAt[0], 10)
  }

  func testRevealedVideoStaysRevealedWhileItPlays() {
    let t = tracker()
    settledWithAdAt1(t)
    t.reveal([1])
    for k in 0..<20 {
      let s = t.observe([h(1), h(300 + UInt64(k)), h(3), h(4)], judging: false)
      t.record(Dictionary(uniqueKeysWithValues: s.toJudge.map { ($0, ad) }), judgedHashes: s.judgedHashes)
    }
    XCTAssertEqual(masked(t), [])
  }
}

/// Stands in for api.openai.com: answers by looking at what was asked.
final class StubProtocol: URLProtocol {
  nonisolated(unsafe) static var handler: (([String: Any]) -> [String: Any])?
  nonisolated(unsafe) static var seen: [[String: Any]] = []
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var data = request.httpBody
    if data == nil, let stream = request.httpBodyStream {
      stream.open(); defer { stream.close() }
      var buf = [UInt8](repeating: 0, count: 1 << 16), out = Data()
      while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; out.append(buf, count: n) }
      data = out
    }
    let body = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
    StubProtocol.seen.append(body)
    let reply = try! JSONSerialization.data(withJSONObject: StubProtocol.handler?(body) ?? [:])
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

final class JudgeTests: XCTestCase {
  func client() -> DecisionsClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return DecisionsClient(key: "sk-test", session: URLSession(configuration: config))
  }
  let bubbles = [Bubbles.common[0], Bubbles.common[1]] // ads, memes

  func testTilesOneRequestPerCellPredicatePerBubble() async {
    StubProtocol.seen = []
    StubProtocol.handler = { body in
      let names = (body["questions"] as! [[String: Any]]).map { $0["name"] as! String }
      return ["answers": names.map { ["type": "predicate", "name": $0, "probability": $0 == "ads" ? 0.9 : 0.1] }]
    }
    let judge = Judge(client: client(), bubbles: bubbles, threshold: 0.6, mode: .tiles)
    let img = TestImages.stripes(width: 400, height: 200, period: 10)
    let r = await judge.judge(img, spec: GridSpec(cols: 2, rows: 1), cells: [0, 1])
    XCTAssertEqual(StubProtocol.seen.count, 2)
    XCTAssertTrue(r.errors.isEmpty, "\(r.errors)")
    XCTAssertEqual(r.verdicts[0]?.reasons, ["Ads"])
    XCTAssertEqual(r.verdicts[1]?.hide, true)
    let content = ((StubProtocol.seen[0]["input"] as! [[String: Any]])[0]["content"]) as! [[String: Any]]
    XCTAssertTrue((content[1]["image_url"] as! String).hasPrefix("data:image/jpeg;base64,"))
  }

  func testGridChunksQuestionsAndReadsChoices() async {
    StubProtocol.seen = []
    StubProtocol.handler = { body in
      let names = (body["questions"] as! [[String: Any]]).map { $0["name"] as! String }
      return ["answers": names.map { n in
        let meme = n == "B1"
        return ["type": "choice", "name": n, "choice": meme ? "memes" : "keep",
                "probabilities": [["value": "keep", "probability": meme ? 0.1 : 0.9], ["value": "ads", "probability": 0.05], ["value": "memes", "probability": meme ? 0.85 : 0.05]]]
      }]
    }
    let judge = Judge(client: client(), bubbles: bubbles, mode: .grid, chunk: 4)
    let img = TestImages.stripes(width: 800, height: 400, period: 10)
    let spec = GridSpec(cols: 4, rows: 2)
    let r = await judge.judge(img, spec: spec, cells: Array(0..<8))
    XCTAssertEqual(StubProtocol.seen.count, 2)               // 8 questions in chunks of 4
    XCTAssertEqual(r.verdicts.count, 8)
    XCTAssertEqual(r.verdicts.filter { $0.value.hide }.map(\.key), [1])
    XCTAssertEqual(r.verdicts[1]?.reasons, ["Memes"])
  }

  func testFailedRequestLeavesCellUnjudged() async {
    StubProtocol.handler = { _ in ["error": "nope"] }
    let judge = Judge(client: client(), bubbles: bubbles, mode: .tiles)
    let r = await judge.judge(TestImages.stripes(width: 200, height: 100, period: 10), spec: GridSpec(cols: 1, rows: 1), cells: [0])
    XCTAssertTrue(r.verdicts.isEmpty)
    XCTAssertEqual(r.errors.count, 1)
  }
}

enum TestImages {
  static func stripes(width: Int, height: Int, period: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    var x = 0
    while x < width { ctx.fill(CGRect(x: x, y: 0, width: period / 2, height: height)); x += period }
    return ctx.makeImage()!
  }
}

final class SegmenterTests: XCTestCase {
  func testParsesTopLevelBoxesAsPixelRects() throws {
    let json = #"{"masks":[{"url":"x"}],"boxes":[[0.5,0.5,0.5,0.25]],"scores":[0.8]}"#
    let boxes = try SAMClient.parse(Data(json.utf8), width: 400, height: 200)
    XCTAssertEqual(boxes, [SAMBox(rect: CGRect(x: 100, y: 75, width: 200, height: 50), score: 0.8)])
  }

  func testParsesMetadataBoxes() throws {
    let json = #"{"masks":[],"metadata":[{"index":0,"score":0.6,"box":[0.25,0.25,0.5,0.5]}]}"#
    let boxes = try SAMClient.parse(Data(json.utf8), width: 100, height: 100)
    XCTAssertEqual(boxes.first?.rect, CGRect(x: 0, y: 0, width: 50, height: 50))
    XCTAssertEqual(boxes.first?.score, 0.6)
  }

  func testShapesDropWeakTinyAndWholeCropBoxes() {
    let area = CGRect(x: 100, y: 100, width: 300, height: 300)
    let shapes = Refine.shapes([
      SAMBox(rect: CGRect(x: 10, y: 10, width: 100, height: 80), score: 0.9),   // kept, moved into image space
      SAMBox(rect: CGRect(x: 10, y: 10, width: 100, height: 80), score: 0.1),   // too unsure
      SAMBox(rect: CGRect(x: 0, y: 0, width: 10, height: 10), score: 0.9),      // too small
      SAMBox(rect: CGRect(x: -5, y: -5, width: 310, height: 310), score: 0.9),  // the whole crop
      SAMBox(rect: CGRect(x: 250, y: 250, width: 100, height: 100), score: 0.9), // clipped to the area
    ], area: area)
    XCTAssertEqual(shapes, [CGRect(x: 110, y: 110, width: 100, height: 80), CGRect(x: 350, y: 350, width: 50, height: 50)])
  }

  func testSearchAreaAddsHalfACellClampedToImage() {
    let spec = GridSpec(cols: 4, rows: 2)
    let area = Refine.searchArea(CellBlock(col0: 0, row0: 0, col1: 1, row1: 0), spec: spec, width: 400, height: 200)
    XCTAssertEqual(area, CGRect(x: 0, y: 0, width: 250, height: 150))
  }
}

final class OpenRouterTests: XCTestCase {
  func testKeyPicksRoute() {
    XCTAssertEqual(DecisionsClient(key: "sk-or-v1-abc").url.absoluteString, "https://openrouter.ai/api/alpha/decisions")
    XCTAssertEqual(DecisionsClient(key: "sk-or-v1-abc").model, "openai/gpt-6-luna-decisions")
    XCTAssertEqual(DecisionsClient(key: "sk-proj-abc").url.absoluteString, "https://api.openai.com/v1/decisions")
  }

  func testBodyPutsImageInStateAndKeysQuestions() {
    let body = Decisions.body(text: "hi", imageDataURL: "data:image/jpeg;base64,AAA",
                              questions: [.predicate(name: "ads", instructions: "ad?"),
                                          .choice(name: "C2", instructions: "what?", choices: [("keep", "other"), ("ads", "an ad")])],
                              model: "openai/gpt-6-luna-decisions", route: .openrouter)
    let state = body["state"] as! [[String: Any]]
    XCTAssertEqual(state[0]["type"] as? String, "text")
    XCTAssertEqual((state[1]["image_url"] as? [String: String])?["url"], "data:image/jpeg;base64,AAA")
    let qs = body["questions"] as! [String: [String: Any]]
    XCTAssertEqual(qs["ads"]?["type"] as? String, "noul")
    XCTAssertEqual(qs["C2"]?["criteria"] as? [String: String], ["keep": "other", "ads": "an ad"])
  }

  func testParsesKeyedAnswers() throws {
    // As OpenRouter returned it on 2026-10-09.
    let json = #"{"model":"openai/gpt-6-luna-decisions-20261006","answers":{"ads":{"type":"noul","noul":0.8},"kind":{"type":"choice","choice":"ads","probabilities":{"keep":0,"ads":1},"confidence":1}},"usage":{"input_tokens":273}}"#
    let a = try Decisions.parse(Data(json.utf8))
    XCTAssertEqual(a["ads"]?.probability, 0.8)
    XCTAssertEqual(a["kind"]?.choice, "ads")
    XCTAssertEqual(a["kind"]?.probabilities["ads"], 1)
  }
}

final class FineRefineTests: XCTestCase {
  func testAreaAndFineGrid() {
    let spec = GridSpec(cols: 4, rows: 2) // 100x100 cells on 400x200
    let block = CellBlock(col0: 1, row0: 0, col1: 1, row1: 0)
    let area = FineRefine.area(block, spec: spec, width: 400, height: 200, margin: 0.5)
    XCTAssertEqual(area, CGRect(x: 50, y: 0, width: 200, height: 150))
    XCTAssertEqual(FineRefine.fineSpec(area: area, spec: spec, width: 400, height: 200, sub: 3), GridSpec(cols: 6, rows: 5))
  }

  func testYesSubcellsBecomeImageRects() async {
    StubProtocol.seen = []
    // Say yes to subcells B2 and C2 only.
    StubProtocol.handler = { body in
      let names = (body["questions"] as! [[String: Any]]).map { $0["name"] as! String }
      return ["answers": names.map { ["type": "predicate", "name": $0, "probability": ["B2", "C2"].contains($0) ? 0.9 : 0.1] }]
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    let client = DecisionsClient(key: "sk-test", session: URLSession(configuration: config))
    let spec = GridSpec(cols: 4, rows: 2)
    let r = await FineRefine.block(CellBlock(col0: 1, row0: 0, col1: 1, row1: 0), image: TestImages.stripes(width: 400, height: 200, period: 10),
                                   spec: spec, matched: [Bubbles.common[0]], client: client)
    XCTAssertTrue(r.errors.isEmpty, "\(r.errors)")
    // Area x 50..250, y 0..150 cut 6x5: subcells are 33.3 x 30; B2..C2 is x 83..150, y 30..60.
    XCTAssertEqual(r.rects.count, 1)
    XCTAssertEqual(r.rects[0].minX, 50 + 200.0 / 6, accuracy: 1)
    XCTAssertEqual(r.rects[0].maxX, 50 + 200.0 / 2, accuracy: 1)
    XCTAssertEqual(r.rects[0].minY, 30, accuracy: 1)
    XCTAssertEqual(r.rects[0].maxY, 60, accuracy: 1)
    let q = (StubProtocol.seen[0]["questions"] as! [[String: Any]])[0]["instructions"] as! String
    XCTAssertTrue(q.contains("advertisement"))
  }

  func testCoverage() {
    let c = Coverage.score(masked: [CGRect(x: 0, y: 0, width: 100, height: 100)], truth: [CGRect(x: 50, y: 0, width: 100, height: 100)],
                           width: 200, height: 100, step: 2)
    XCTAssertEqual(Double(c.overlap) / Double(c.truthArea), 0.5, accuracy: 0.02)
    XCTAssertEqual(Double(c.overlap) / Double(c.maskedArea), 0.5, accuracy: 0.02)
  }
}

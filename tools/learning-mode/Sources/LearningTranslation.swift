// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NaturalLanguage
import Translation

struct LearningQuery: Hashable {
  enum Direction { case english, chinese }
  let text: String
  let direction: Direction

  // Use committed-text preview, never the raw pinyin. Do not send switcher items,
  // digit-triggered private phrases or an incomplete Latin spelling to the engine.
  static func candidate(preview: String, highlighted: String, raw: String) -> Self? {
    guard !raw.isEmpty, raw.first?.isLetter == true,
          !highlighted.isEmpty, !preview.isEmpty else { return nil }
    if preview.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
      guard preview.hasSuffix(highlighted), highlighted.unicodeScalars.contains(where: { $0.properties.isIdeographic }) else { return nil }
      return Self(text: preview, direction: .english)
    }
    guard preview == highlighted, preview.range(of: "[A-Za-z]", options: .regularExpression) != nil else { return nil }
    return Self(text: preview, direction: .chinese)
  }
}

/// Rime can preview “清dj”: the selected word covers qk but dj is still editable.
/// Use the composition's selection boundary, not a guess based on Latin letters
/// (a real mixed candidate can legitimately end in e.g. “docker”).
struct CandidateReading {
  let query: LearningQuery
  let remainder: String

  init?(preview: String, highlighted: String, raw: String, prefix: Substring, tail: Substring) {
    let converted = String(prefix) + highlighted
    let partial = !tail.isEmpty && raw.hasSuffix(tail) && preview == converted + tail
    let text = partial ? converted : preview
    guard let query = LearningQuery.candidate(preview:text, highlighted:highlighted, raw:raw) else { return nil }
    self.query = query
    self.remainder = partial ? String(tail) : ""
  }
}

enum LearningReply: Equatable {
  case translated(String), unavailable(String), dictionary([LexicalChoice])

  var first: String? {
    switch self {
    case let .translated(s): s
    case let .dictionary(items): items.first?.text
    case .unavailable: nil
    }
  }

  var line: LearningLine {
    switch self {
    case let .translated(s): return LearningLine(text: s, isTranslation: true)
    case let .unavailable(s): return LearningLine(text: s, isTranslation: false)
    case let .dictionary(items):
      if items.count == 1 { return LearningLine(text: items[0].text, isTranslation: true) }
      var text = ""
      var labels: [NSRange] = []
      for (i, item) in items.enumerated() {
        if i > 0 { text += "　" }
        let number = String(i+1)
        labels.append(NSRange(location: text.utf16.count, length: number.utf16.count))
        text += number + "\u{00a0}" + item.text
        if !item.hint.isEmpty { text += " " + item.hint }
      }
      return LearningLine(text: text, isTranslation: !items.isEmpty, labelRanges: labels)
    }
  }
}

struct LearningLine: Equatable {
  static let pending = Self(text: "", isTranslation: false)
  let text: String
  let isTranslation: Bool
  var labelRanges: [NSRange] = []
}

// The translator often capitalizes a standalone fragment like a sentence.
// Change just its first letter when we can identify an ordinary English term.
enum EnglishTermCase {
  static func format(_ text: String, for query: LearningQuery) -> String {
    let head = text.prefix(while: { $0.isLetter })
    guard query.direction == .english, let initial = head.first, initial.isASCII, initial.isUppercase,
          head != "I", head.dropFirst().allSatisfy({ $0.isLowercase }),
          text.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?。！？\n")) == nil,
          query.text.rangeOfCharacter(from: CharacterSet(charactersIn: "。！？.!?\n")) == nil,
          !query.text.split(whereSeparator: { !$0.isASCII || !$0.isLetter }).contains(where: { $0.lowercased() == head.lowercased() })
    else { return text }
    // Uppercase elsewhere can be meaningful, e.g. Spring Boot or New York.
    guard !text.dropFirst(head.count).contains(where: { $0.isUppercase }) else { return text }
    let range = text.startIndex..<text.endIndex
    let tagger = NLTagger(tagSchemes:[.nameTypeOrLexicalClass, .lemma])
    tagger.string = text
    tagger.setLanguage(.english, range:range)
    let (lemma, _) = tagger.tag(at:text.startIndex, unit:.word, scheme:.lemma)
    var tags = [NLTag]()
    tagger.enumerateTags(in:range, unit:.word, scheme:.nameTypeOrLexicalClass, options:[.omitWhitespace,.omitPunctuation]) { tag, _ in
      if let tag { tags.append(tag) }
      return true
    }
    // The isolated fruit and the company share the English spelling.
    let literalFruit = query.text == "苹果" && text == "Apple"
    guard literalFruit || (lemma?.rawValue.first?.isLowercase == true &&
      ![NLTag.personalName,.placeName,.organizationName].contains(where: { $0 == tags.first })) else { return text }
    if tags.count > 1 {
      // Preserve clauses and commands even with no final period. An initial
      // participle can head a term ("operating system"), as can a word
      // misclassified as a verb in a dangling fragment ("deoxyribose and").
      let word = head.lowercased()
      if tags.dropFirst().contains(.verb) || (tags.first == .verb && tags.last != .conjunction &&
          !word.hasSuffix("ing") && !word.hasSuffix("ed")) { return text }
    }
    return initial.lowercased() + text.dropFirst()
  }
}

// No network calls, files of typed text, command-line processes or blocking calls on the keyboard path.
actor LearningEngine {
  static let shared = LearningEngine()
  private var sessions: [LearningQuery.Direction: TranslationSession] = [:]

  private lazy var lexicon: LexicalIndex? = {
    #if LEARNING_TESTS
    guard let path = ProcessInfo.processInfo.environment["RIME_TEST_SENSES_DB"] else { return nil }
    return LexicalIndex(url: URL(fileURLWithPath: path))
    #else
    return LexicalIndex(url: LexicalIndex.hanYingURL)
    #endif
  }()

  private lazy var longman: LexicalIndex? = {
    #if LEARNING_TESTS
    guard let path = ProcessInfo.processInfo.environment["RIME_TEST_LONGMAN_DB"] else { return nil }
    return LexicalIndex(url: URL(fileURLWithPath:path))
    #else
    return LexicalIndex(url: LexicalIndex.longmanURL)
    #endif
  }()

  func translate(_ query: LearningQuery) async -> LearningReply {
    if query.direction == .chinese {
      let word = query.text
      var choices = longman?.choices(for:word) ?? []
      if choices.isEmpty && word.lowercased() != word { choices = longman?.choices(for:word.lowercased()) ?? [] }
      if choices.isEmpty && word.count <= 6 && word.uppercased() != word { choices = longman?.choices(for:word.uppercased()) ?? [] }
      if ["llm","llms","large language model"].contains(word.lowercased()) {
        // Contemporary developer usage complements Longman's degree entry.
        choices = [LexicalChoice(text:"大语言模型",hint:"")] + choices.filter { $0.text != "大语言模型" }
      }
      if !choices.isEmpty { return .dictionary(Array(choices.prefix(3))) }
    }
    if query.direction == .english, let choices = lexicon?.choices(for: query.text), !choices.isEmpty {
      return .dictionary(choices)
    }
    let source = Locale.Language(identifier: query.direction == .english ? "zh-CN" : "en-US")
    let target = Locale.Language(identifier: query.direction == .english ? "en-US" : "zh-CN")
    let session = sessions[query.direction] ?? TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
    sessions[query.direction] = session
    do {
      let result = try await session.translate(query.text).targetText.trimmingCharacters(in: .whitespacesAndNewlines)
      return result.isEmpty ? .unavailable("没有译文") : .translated(EnglishTermCase.format(result, for:query))
    } catch {
      sessions.removeValue(forKey: query.direction)
      if TranslationError.notInstalled ~= error {
        return .unavailable("请在「语言与地区」下载简体中文和美式英语")
      }
      return .unavailable("本机翻译暂不可用")
    }
  }
}

// IMK callbacks run on the AppKit main run loop (the Objective-C SDK is unannotated).
final class LearningPreview {
  typealias Translate = @Sendable (LearningQuery) async -> LearningReply
  private let translate: Translate
  private let delay: Duration
  private var debounce: Task<Void, Never>?
  private var running = false
  private var queued: LearningQuery?
  private var cache: [LearningQuery: LearningReply] = [:]
  private var order: [LearningQuery] = []
  private var epoch = 0
  private var spelling: String?
  private(set) var query: LearningQuery?
  private(set) var reply: LearningReply?
  var changed: (() -> Void)?

  init(delay: Duration = .milliseconds(380), translate: @escaping Translate = { await LearningEngine.shared.translate($0) }) {
    self.delay = delay; self.translate = translate
  }

  func update(_ next: LearningQuery?, spelling raw: String? = nil) {
    // Rime can keep the same first choice as a second key completes its syllable.
    // Count that key as typing too; a repaint with identical input is not typing.
    let input = next == nil ? nil : raw
    guard next != query || spelling != input else { return }
    spelling = input
    epoch &+= 1
    query = next; reply = nil; queued = nil; debounce?.cancel()
    guard let next else { return }
    debounce = Task { @MainActor [weak self, delay] in
      do { try await Task.sleep(for: delay) } catch { return }
      guard let self, self.query == next else { return }
      // A cache hit must obey the same quiet period as an uncached result.
      if let saved = self.cache[next] {
        self.reply = saved; self.changed?(); return
      }
      self.queued = next
      self.pump()
    }
  }

  // At most one model request and one replaceable pending request per controller.
  private func pump() {
    guard !running, let input = queued else { return }
    queued = nil; running = true
    let generation = epoch
    Task { @MainActor [weak self, translate] in
      let answer = await translate(input)
      guard let self else { return }
      self.running = false
      if self.epoch == generation, self.query == input {
        if answer.first != nil, self.cache[input] == nil {
          if self.order.count >= 32 { self.cache.removeValue(forKey: self.order.removeFirst()) }
          self.order.append(input); self.cache[input] = answer
        }
        self.reply = answer; self.queued = nil
        self.changed?()
      }
      self.pump()
    }
  }

  var translation: String? { reply?.first }
  func numbered(_ i: Int) -> String? {
    guard case let .dictionary(items) = reply, items.count > 1, items.indices.contains(i) else { return nil }
    return items[i].text
  }
  var line: LearningLine? {
    guard query != nil else { return nil }
    guard let reply else { return .pending }
    return reply.line
  }
  func reset() {
    guard query != nil || !order.isEmpty else { return }
    update(nil); order.removeAll(); cache.removeAll()
  }
}

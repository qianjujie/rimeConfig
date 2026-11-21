import Foundation
// A controllably slow engine for the "old translation arrives after typing" case.
actor SlowEngine {
  var inputs = [String]()
  var awaiting: CheckedContinuation<LearningReply, Never>?
  func translate(_ q: LearningQuery) async -> LearningReply {
    inputs.append(q.text)
    return await withCheckedContinuation { awaiting = $0 }
  }
  func answer(_ reply: LearningReply) { let c = awaiting; awaiting = nil; c?.resume(returning: reply) }
}
@main struct StateChecks {
  @MainActor static func main() async throws {
    let model = SlowEngine()
    let p = LearningPreview(delay: .milliseconds(10)) { await model.translate($0) }
    func query(_ text: String) -> LearningQuery { LearningQuery(text: text, direction: .english) }
    for (source, raw, expected) in [
      ("数据库","Database","database"), ("部署到","Deployment to","deployment to"),
      ("脱氧核糖和","Deoxyribose and","deoxyribose and"), ("操作系统","Operating system","operating system"),
      ("苹果","Apple","apple"), ("苹果公司","Apple","Apple"), ("脱氧核糖核酸","DNA","DNA"),
      ("手机","iPhone","iPhone"), ("Docker部署","Docker deployment","Docker deployment"),
      ("我","I","I"), ("北京","Beijing","Beijing"), ("星期一","Monday","Monday"),
      ("纽约","New York","New York"), ("字体很小","The font is very small.","The font is very small."),
      ("字号很小","The font is very small","The font is very small"), ("开门","Open the door","Open the door")
    ] {
      precondition(EnglishTermCase.format(raw, for:query(source)) == expected, raw)
    }
    precondition(EnglishTermCase.format("Docker 部署", for:LearningQuery(text:"Docker deployment",direction:.chinese)) == "Docker 部署")
    func until(_ condition: () async -> Bool) async throws {
      for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
      }
      fatalError("timed out")
    }
    let steady = LearningPreview(delay:.milliseconds(100)) { _ in .translated("what") }
    steady.update(query("什么"), spelling:"ufm")
    try await Task.sleep(for:.milliseconds(65))
    steady.update(query("什么"), spelling:"ufme")
    try await Task.sleep(for:.milliseconds(60))
    precondition(steady.translation == nil && steady.line == .pending)
    try await until {steady.translation == "what"}
    steady.reset()
    p.update(query("今")); p.update(query("今天"))
    precondition(p.line == .pending && p.translation == nil)
    try await until { await model.inputs == ["今天"] }
    p.update(query("明")); p.update(query("明天"))
    try await Task.sleep(for: .milliseconds(25))
    await model.answer(.translated("today"))
    try await until { await model.inputs == ["今天", "明天"] }
    precondition(p.line == .pending && p.translation == nil && p.query?.text == "明天")
    await model.answer(.translated("tomorrow"))
    try await until { p.translation == "tomorrow" }
    p.update(query("路上")); p.update(query("明天"))
    precondition(p.line == .pending && p.translation == nil)
    try await until { p.translation == "tomorrow" }
    let count = await model.inputs.count
    precondition(count == 2)
    p.update(query("明天开会")); try await until { await model.inputs.count == 3 }
    p.reset(); await model.answer(.translated("stale")); try await Task.sleep(for: .milliseconds(25))
    precondition(p.query == nil && p.line == nil && p.translation == nil)
    p.update(query("你好")); try await until { await model.inputs.count == 4 }
    await model.answer(.unavailable("语言包不可用")); try await until { p.reply != nil }
    precondition(p.translation == nil && p.line == LearningLine(text: "语言包不可用", isTranslation: false))
    precondition(LearningQuery.candidate(preview: "苹果go", highlighted: "苹果", raw:"pkgo") == nil)
    precondition(LearningQuery.candidate(preview: "苹果", highlighted: "苹果", raw:"123") == nil)
    let partial = CandidateReading(preview:"水清dj",highlighted:"清",raw:"uvqkdj",prefix:"水",tail:"dj")
    precondition(partial?.query.text == "水清" && partial?.remainder == "dj")
    let mixed = CandidateReading(preview:"我用docker",highlighted:"我用docker",raw:"woysdocker",prefix:"",tail:"")
    precondition(mixed?.query.text == "我用docker" && mixed?.remainder == "")
    precondition(CandidateReading(preview:"清dj",highlighted:"清",raw:"qkdj",prefix:"",tail:"") == nil)
    var en = EnglishDraft(); en.insert("we meet"); en.move(-4); en.insert("can "); precondition(en.text == "we can meet")
    en.erase(backwards: true); en.erase(backwards: false); precondition(en.text == "we caneet")
    print("PASS: debounce, single in-flight translation, stale/focus loss, error state, English cursor and spaces")
  }
}

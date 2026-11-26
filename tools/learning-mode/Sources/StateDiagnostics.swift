// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Carbon

// One writer in the running IME. Only enums, scalar measurements and time cross
// the logging boundary: no key events, Rime context, text client or rendered strings.
final class StateDiagnostics {
  static let shared = StateDiagnostics()
  static let preference = "StateDiagnosticsEnabled"
  static let settingsChanged = Notification.Name("RimeLearningDiagnosticsSettingsChanged")
  static let sampleRequested = Notification.Name("RimeLearningDiagnosticsSample")
  #if LEARNING_TESTS
  static let directory = SquirrelApp.userDir.appendingPathComponent("Diagnostics")
  static let defaults = UserDefaults(suiteName:"local.rime.diagnostics.tests.\(ProcessInfo.processInfo.processIdentifier)")!
  #else
  static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RimeLearning")
  static let defaults = UserDefaults.standard
  #endif
  static let file = directory.appendingPathComponent("state.jsonl")
  enum Source: String, Codable {
    case learning, weType, squirrel, us, appleOther, other, unknown
    static func identify(_ id: String?) -> Self {
      guard let id else { return .unknown }
      if id == "local.rime.inputmethod.Learning.Hans" { return .learning }
      if id.hasPrefix("com.tencent.inputmethod.wetype.") { return .weType }
      if id.hasPrefix("im.rime.inputmethod.Squirrel.") { return .squirrel }
      if ["com.apple.keylayout.US","com.apple.keylayout.ABC"].contains(id) { return .us }
      return id.hasPrefix("com.apple.") ? .appleOther : .other
    }
  }
  enum Event: String, Codable { case started, stopped, enabled, disabled, mode, selectionNotice, settled, active, inactive, snapshot, layout, preview, status, hidden }
  struct SizeState: Codable, Equatable {
    let rows: Int
    let heightPt: Int
    let sourceHeightPt: Int
    let captionVisible: Bool
  }
  private struct Record: Encodable {
    var at = Date()
    let event: Event
    var from: Source?
    var source: Source?
    var secure: Bool?
    var ascii: Bool?
    var panel: SizeState?
  }

  private let writer = DispatchQueue(label:"local.rime.learning.state-log", qos:.utility)
  private var observer: NSObjectProtocol?
  private var timer: Timer?
  private var lastSource: Source?
  private var lastPanel: SizeState?
  private var wasStatus = false
  private var lastASCII: Bool?
  private var writeFailed = false // writer queue only
  private(set) var enabled = false
  private static func inspect() -> (Source, Bool) {
    let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    let id = src.flatMap { TISGetInputSourceProperty($0,kTISPropertyInputSourceID) }.map {
      Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
    }
    return (.identify(id), IsSecureEventInputEnabled())
  }
  #if LEARNING_TESTS
  var panelIsSecure = IsSecureEventInputEnabled
  var readSource = StateDiagnostics.inspect
  #else
  private let panelIsSecure = IsSecureEventInputEnabled
  private let readSource = StateDiagnostics.inspect
  #endif

  func applyPreference(onLaunch: Bool = false) {
    let wanted = Self.defaults.bool(forKey:Self.preference)
    guard wanted != enabled else { return }
    enabled = wanted
    if wanted {
      observer = DistributedNotificationCenter.default().addObserver(forName:Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
          object:nil, queue:.main) { [weak self] _ in self?.sample(.selectionNotice) }
      sample(onLaunch ? .started : .enabled)
    } else {
      timer?.invalidate(); timer = nil
      if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
      observer = nil; lastASCII = nil; lastSource = nil; lastPanel = nil; wasStatus = false
      append(Record(event:.disabled))
      writer.sync {} // All events up to the off marker are visible when the switch returns.
    }
  }

  func sample(_ event: Event) {
    guard enabled else { return }
    if event == .active || event == .inactive { lastASCII = nil }
    let (now,secure) = readSource()
    append(Record(event:event, from:lastSource, source:now, secure:secure))
    lastSource = now
    if event != .settled {
      timer?.invalidate()
      let t = Timer(fire:Date(timeIntervalSinceNow:1.5), interval:0, repeats:false) { [weak self] _ in self?.sample(.settled) }
      timer = t; RunLoop.main.add(t, forMode:.common)
    }
  }

  func stopped() {
    guard enabled else { return }
    timer?.invalidate()
    append(Record(event:.stopped)); writer.sync {}
  }

  func mode(ascii: Bool) {
    guard enabled, lastASCII != ascii else { return }
    lastASCII = ascii; append(Record(event:.mode, ascii:ascii))
  }

  func panel(_ event: Event, _ state: SizeState) {
    guard enabled else { return }
    // No layout trace during Secure Event Input. Source samples can still show this flag.
    guard !panelIsSecure() else { lastPanel = nil; return }
    guard state != lastPanel || wasStatus != (event == .status) else { return }
    lastPanel = state; wasStatus = event == .status
    append(Record(event:event, panel:state))
  }
  func hidden() {
    guard enabled, lastPanel != nil else { return }
    lastPanel = nil; wasStatus = false
    if !panelIsSecure() { append(Record(event:.hidden)) }
  }

  private func append(_ record: Record) {
    writer.async {
      do { try self.write(record); self.writeFailed = false }
      catch {
        if !self.writeFailed { NSLog("RimeLearning: state diagnostic log could not be written") }
        self.writeFailed = true
      }
    }
  }
  // The input thread never opens a file. Rotate at 512 KiB, retaining one previous file.
  private lazy var encoder: JSONEncoder = {
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    stamp.timeZone = .current
    let e = JSONEncoder()
    e.dateEncodingStrategy = .custom { date, encoder in
      var value = encoder.singleValueContainer(); try value.encode(stamp.string(from:date))
    }
    e.outputFormatting = .sortedKeys
    return e
  }()
  private func write(_ record: Record) throws {
    let fm = FileManager.default
    try fm.createDirectory(at:Self.directory, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
    var data = try encoder.encode(record); data.append(10)
    if let size = (try? fm.attributesOfItem(atPath:Self.file.path)[.size]) as? NSNumber,
       size.intValue + data.count > 512 * 1024 {
      let previous = Self.directory.appendingPathComponent("state.previous.jsonl")
      if rename(Self.file.path,previous.path) != 0 { throw POSIXError(.EIO) }
    }
    let fd = Darwin.open(Self.file.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
    try handle.write(contentsOf:data)
  }
}

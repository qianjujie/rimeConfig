// Refresh a replaced input method at its installed URL, even when the mode is already enabled.
import Cocoa
import Carbon
// Updating must not force a second IME into the front application or enable
// stock Squirrel behind the user's back. Leave other selections alone.
if CommandLine.arguments.dropFirst().first == "--prepare" {
  guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
        let raw = TISGetInputSourceProperty(current, kTISPropertyInputSourceID) else { exit(1) }
  let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
  if id == "local.rime.inputmethod.Learning.Hans" {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.tencent.xinWeChat" else {
      FileHandle.standardError.write(Data("请先将其他应用切到前台，再升级；不在微信里切换输入法。\n".utf8)); exit(1)
    }
    guard let latin = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          TISSelectInputSource(latin) == noErr else { exit(1) }
    print("restore-learning")
  } else { print("keep-selection") }
  exit(0)
}
let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/RimeLearning.app", isDirectory: true)
guard Bundle(url: url)?.bundleIdentifier == "local.rime.inputmethod.Learning" else { exit(2) }
let appResult = LSRegisterURL(url as CFURL, true)
guard appResult == noErr else { print("Application registration failed: \(appResult)"); exit(1) }
let inputResult = TISRegisterInputSource(url as CFURL)
guard inputResult == noErr else { print("Input source registration failed: \(inputResult)"); exit(1) }
print("Refreshed installed learning input source.")

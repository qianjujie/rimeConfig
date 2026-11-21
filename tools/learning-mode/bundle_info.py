"""Change only the staged package's identity. Its input modes must not collide with Squirrel."""
from pathlib import Path
import plistlib, sys, subprocess
c = Path(sys.argv[1])
old, new = "im.rime.inputmethod.Squirrel", "local.rime.inputmethod.Learning"
def update(value):
    if isinstance(value, dict): return {k.replace(old, new): update(v) for k, v in value.items()}
    if isinstance(value, list): return list(map(update, value))
    if isinstance(value, str): return value.replace(old, new)
    return value
p = c / "Info.plist"
info = update(plistlib.loads(p.read_bytes()))
info.update(CFBundleName="RimeLearning", CFBundleDisplayName="鼠须管·学英语", CFBundleExecutable="RimeLearning",
            InputMethodConnectionName=new+"_Connection", LSMinimumSystemVersion="26.4")
# Some host applications ask macOS for the parent input method, not the Hans mode.
# Publish the same real icon and language at both levels.
info["tsInputMethodIconFileKey"] = "rime.pdf"
info["TISIntendedLanguage"] = "zh-Hans"
info["tsInputMethodCharacterRepertoireKey"] = ["Hans", "Latn"]
modes = info["ComponentInputModeDict"]
modes["tsInputModeListKey"].pop(new+".Hant", None)
modes["tsVisibleInputModeOrderedArrayKey"] = [new+".Hans"]
info["CFBundleVersion"] = "2.7.6"
info["CFBundleShortVersionString"] = "2.7.6"
for key in list(info):
    if key.startswith("SU"): del info[key]
p.write_bytes(plistlib.dumps(info))
for p in (c/"Resources").glob("*.lproj/InfoPlist.strings"):
    strings = update(plistlib.loads(subprocess.check_output(["plutil", "-convert", "binary1", "-o", "-", str(p)])))
    for key in ("CFBundleName", "CFBundleDisplayName", new, new+".Hans", new+".Hant"):
        strings[key] = "鼠须管·学英语" if key != new+".Hant" else "鼠鬚管·學英語"
    p.write_bytes(plistlib.dumps(strings))

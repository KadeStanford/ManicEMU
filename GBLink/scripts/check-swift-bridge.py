"""Type-check the real added Swift bridge with small game/toast stubs.
Full Manic build still needs its unrelated binary/submodule dependencies.
"""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
models = root / 'ManicEmu/ManicEmu/Sources/Business/Games/Models'
source = (models / 'GameOptionPerform.swift').read_text()
bridge = source.split('        case .gbLink:\n', 1)[1].split('        case .rename:', 1)[0]
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp) / 'Bridge.swift'
    path.write_text('''import UIKit
import Darwin
enum Platform { case gb, gba }
enum PlayViewController { static var isGaming = false }
struct Game {
    var gameType = Platform.gb
    var romUrl = URL(fileURLWithPath: "/test.gb")
    var gameSaveUrl = URL(fileURLWithPath: "/test.sav")
}
extension UIView { static func makeToast(message: String) {} }
func openLink(firstGame: Game) {
''' + bridge + '\n}\n')
    subprocess.run(['xcrun', 'swiftc', '-typecheck', '-target', 'arm64-apple-ios15.0',
                    '-sdk', sys.argv[1], str(path)], check=True)
    for name in ['GameOption.swift', 'GameOptionPerform.swift']:
        subprocess.run(['xcrun', 'swiftc', '-frontend', '-parse', str(models / name)], check=True)
print('PASS: actual Swift link bridge type-checked; changed option sources parse')

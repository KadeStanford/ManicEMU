"""Run actual registry/model fragments on Swift; no game or UI acceptance claim."""
from pathlib import Path
import re,subprocess,tempfile,plistlib
root=Path(__file__).resolve().parents[2]
source=root/'ManicEmu/ManicEmu/Sources'
registry=(source/'Tools/Others/EmulationCore.swift').read_text()
types=set()
for array in re.findall(r'return \[([^\]]*)\]',registry):
    types.update(re.findall(r'\.([A-Za-z_][A-Za-z_0-9]*)',array))
def fragment(text,marker):
    start=text.index(marker);brace=text.index('{',start);depth=1;i=brace+1
    while depth:
        if text[i]=='{':depth+=1
        elif text[i]=='}':depth-=1
        i+=1
    return text[start:i]
type_source=(source/'Tools/Extensions/GameTypeExtensions.swift').read_text()
model=(source/'Business/Play/Models/Game.swift').read_text()
support=fragment(type_source,'var supportCores: [String]')
fragments=[fragment(model,key) for key in ('var libretroCore:','var libretroCorePath:','var isCitra3DS:','var isAzahar3DS:','var isAzaharFastInterp:')]
fragments=[f.replace('Bundle.main.path(', 'testBundle.path(') for f in fragments]
stubs='\n'.join('var '+n+': Bool { false }' for n in ('isPicodriveCore','isClownMDEmuCore','isGearSystemCore','isSegaArcade'))
text='''import Foundation
enum GameType { case '''+','.join(sorted(types|{'unknown'}))+'''
}
'''+registry+'''
extension GameType { '''+support+''' }
final class Game {
 var gameType: GameType = ._3ds
 var defaultCore: Int = 1
 var fileExtension = "cxi"
 var jit = false
 '''+stubs+'''
 func getExtraBool(key: String) -> Bool? { nil }
 '''+'\n'.join(fragments)+'''
}
enum ExtraKey: String { case snesVRAM }
final class LibretroCore { static func jitAvailable() -> Bool { true } }
let dir=URL(fileURLWithPath:CommandLine.arguments[1])
let testBundle=Bundle(url:dir)!
let options=GameType._3ds.supportCores
precondition(options == ["Citra","Azahar","Azahar FastInterp"])
precondition(!EmulationCore.AzaharFastInterp.supportJit)
precondition(EmulationCore.AzaharFastInterp.isLibretroCore)
precondition(EmulationCore.AzaharFastInterp.gameTypes == [._3ds])
let g=Game()
for (index,core) in [(1,EmulationCore.Azahar),(2,EmulationCore.AzaharFastInterp),(1,EmulationCore.Azahar)] {
 g.defaultCore=index
 precondition(g.libretroCore==core)
 precondition(g.isAzahar3DS)
 precondition(g.isAzaharFastInterp == (index==2))
 let path=g.libretroCorePath!
 precondition(path.hasSuffix(index==2 ? "azahar-fastinterp.libretro.framework" : "azahar.libretro.framework"))
 let persisted=try! JSONEncoder().encode(index)
 g.defaultCore=try! JSONDecoder().decode(Int.self,from:persisted)
 precondition(g.libretroCore==core)
}
g.defaultCore=0
precondition(g.isCitra3DS && !g.isAzahar3DS && g.libretroCore == nil)
print("Actual Swift registry/model fragments: selection, separate paths, index persistence and switch-back passed. No Realm/UI/game acceptance claim.")
'''
with tempfile.TemporaryDirectory(prefix='fastinterp-selection-') as d:
    tmp=Path(d);bundle=tmp/'Test.app';(bundle/'Frameworks').mkdir(parents=True)
    (bundle/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'test.fastinterp.selection','CFBundleExecutable':'Test'}))
    for name in ('azahar','azahar-fastinterp'):
        (bundle/'Frameworks'/f'{name}.libretro.framework').mkdir()
    file=tmp/'Selection.swift';file.write_text(text)
    subprocess.run(['xcrun','swiftc','-DSIDE_LOAD',str(file),'-o',str(tmp/'Selection')],check=True)
    subprocess.run([str(tmp/'Selection'),str(bundle)],check=True)


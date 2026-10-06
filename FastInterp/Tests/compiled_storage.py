"""Exercise routing inside the built native core with the iOS storage branch.

Uses an invalid public placeholder ROM, never private game/save/plugin input.
Each case runs in a fresh process because core global state persists by design.
"""
import argparse,ctypes,json,pathlib,subprocess,sys,tempfile
p=argparse.ArgumentParser()
p.add_argument('--core',required=True)
p.add_argument('--output')
p.add_argument('--case',nargs=2,metavar=('ROOT_SUFFIX','OPTION'))
a=p.parse_args()
if not a.case:
    rows=[]
    for suffix in ['','3DS','3ds']:
        for option in ['LibRetro Default','Azahar Default']:
            r=subprocess.run([sys.executable,__file__,'--core',a.core,'--case',suffix,option],capture_output=True,text=True,timeout=30)
            if r.returncode:raise RuntimeError(r.stderr[-3000:]+r.stdout[-3000:])
            rows.append(json.loads(r.stdout))
    report={'compiled_core_routing_passed':True,'cases':rows,'private_inputs':False,'game_boot_verified':False,'phone_execution':False,'native_build_uses_test_ios_storage_branch':True}
    pathlib.Path(a.output).write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))
    raise SystemExit(0)

class Variable(ctypes.Structure):
    _fields_=[('key',ctypes.c_char_p),('value',ctypes.c_char_p)]
class Game(ctypes.Structure):
    _fields_=[('path',ctypes.c_char_p),('data',ctypes.c_void_p),('size',ctypes.c_size_t),('meta',ctypes.c_char_p)]
ENV=ctypes.CFUNCTYPE(ctypes.c_bool,ctypes.c_uint,ctypes.c_void_p)
LOG=ctypes.CFUNCTYPE(None,ctypes.c_int,ctypes.c_char_p)
@LOG
def log(level,fmt):pass
with tempfile.TemporaryDirectory(prefix='manic-built-routing-') as td:
    base=pathlib.Path(td)/'Documents';base.mkdir()
    save=base/a.case[0] if a.case[0] else base
    save.mkdir(exist_ok=True)
    buffers={k:ctypes.create_string_buffer(v.encode()) for k,v in {
        'save':str(save),'system':str(pathlib.Path(td)/'system'),
        'citra_use_libretro_save_path':a.case[1],'citra_graphics_api':'Vulkan',
        'citra_use_cpu_jit':'disabled','citra_use_shader_jit':'disabled','citra_use_fastinterp':'enabled',
    }.items()}
    def put_string(data,key):
        ctypes.cast(data,ctypes.POINTER(ctypes.c_void_p))[0]=ctypes.addressof(buffers[key])
    @ENV
    def environment(command,data):
        if command==9:put_string(data,'system');return True
        if command==31:put_string(data,'save');return True
        if command==27:
            ctypes.cast(data,ctypes.POINTER(ctypes.c_void_p))[0]=ctypes.cast(log,ctypes.c_void_p).value
            return True
        if command==15:
            variable=ctypes.cast(data,ctypes.POINTER(Variable)).contents
            key=variable.key.decode()
            if key not in buffers:return False
            variable.value=ctypes.cast(buffers[key],ctypes.c_char_p)
            return True
        if command==52:ctypes.cast(data,ctypes.POINTER(ctypes.c_uint))[0]=0;return True
        return False
    core=ctypes.CDLL(str(pathlib.Path(a.core).resolve()))
    core.retro_set_environment.argtypes=[ENV]
    core.retro_set_environment(environment)
    core.retro_init()
    placeholder=pathlib.Path(td)/'invalid.cxi';placeholder.write_bytes(b'Public invalid-ROM routing fixture\n')
    game=Game(str(placeholder).encode(),None,0,None)
    core.retro_load_game.argtypes=[ctypes.POINTER(Game)]
    core.retro_load_game.restype=ctypes.c_bool
    loaded=core.retro_load_game(ctypes.byref(game))
    assert not loaded,'Placeholder must not boot'
    core.retro_azahar_storage_path.argtypes=[ctypes.c_uint]
    core.retro_azahar_storage_path.restype=ctypes.c_char_p
    paths=[core.retro_azahar_storage_path(i).decode() for i in range(4)]
    expected=save if a.case[0] else base/'3DS'
    assert pathlib.Path(paths[0])==expected,(paths,expected)
    for path,child in zip(paths[1:],['sdmc','nand','load']):
        assert pathlib.Path(path)==expected/child,(path,expected/child)
    assert expected.is_dir()
    assert not (base/'Azahar').exists()
    assert core.retro_azahar_storage_path(999) is None
    assert core.retro_azahar_cpu_backend()==0
    core.retro_deinit()
    print(json.dumps({'root_suffix':a.case[0],'stored_option':a.case[1],'user_sdmc_nand_load_paths_correct':True,'Azahar_tree_created':False,'invalid_rom_rejected':True,'cpu_not_started':True}))

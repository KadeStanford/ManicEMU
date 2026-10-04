"""Apply lifecycle/reset changes to Manic's public melonDS DS v1.3.1 fork.

This source route is required for a shippable core. The separately verified
binary instrumentation is a diagnostic prototype: the shipped 1.3.1 stop
callback does not clear its queue, and must not be used for repeated sessions.
"""
import argparse,hashlib,pathlib,subprocess
COMMIT='bc4e4b67d2d470d7c682810a1e892cafd6f9082b'
COMPAT_SHA256='2f7f74fb63994137c527372d997e28206b7a578eb2e618271db6b2f296085779'
def patch(root):
    root=pathlib.Path(root)
    commit=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()
    if commit!=COMMIT:raise ValueError('Pinned melonDS DS v1.3.1 required')
    compat=pathlib.Path(__file__).resolve().parents[1]/'patches/manic-v131-compat.patch'
    if hashlib.sha256(compat.read_bytes()).hexdigest()!=COMPAT_SHA256:raise ValueError('Manic compatibility patch checksum mismatch')
    subprocess.check_call(['git','-C',str(root),'apply','--check',str(compat)])
    subprocess.check_call(['git','-C',str(root),'apply',str(compat)])
    changes={}
    def replace(file,before,after):
        p=root/file;s=changes.get(p,p.read_text())
        if s.count(before)!=1:raise ValueError('Exact source guard failed: '+file)
        changes[p]=s.replace(before,after)
    replace('src/libretro/net/mp.hpp','    void SetSendFn(retro_netpacket_send_t sendFn) noexcept;',
            '    void Reset() noexcept;\n    void SetSendFn(retro_netpacket_send_t sendFn) noexcept;')
    replace('src/libretro/net/mp.cpp','bool MpState::IsReady() const noexcept {',
            '''void MpState::Reset() noexcept {
    while (!receivedPackets.empty()) receivedPackets.pop();
    _hostId.reset();
    _timeoutCount = 0;
    _warnedHighLatency = false;
}

bool MpState::IsReady() const noexcept {''')
    replace('src/libretro/platform/mp.cpp','    _mpState.SetSendFn(nullptr);',
            '    _mpState.Reset();\n    _mpState.SetSendFn(nullptr);')
    replace('src/libretro/platform/mp.cpp','    if(!_mpState.IsReady()) {\n        return false;\n    }',
            '''    if(!_mpState.IsReady()) {
        struct Event { uint32_t event; uint32_t reserved; const void* packet; } event{3,0,&p};
        retro::environment(0x4d445301, &event);
        return false;
    }''')
    replace('src/libretro/platform/mp.cpp','void Platform::MP_Begin(void*) {\n    ZoneScopedN(TracyFunction);\n}',
            '''void Platform::MP_Begin(void*) {
    ZoneScopedN(TracyFunction);
    struct Event { uint32_t event; uint32_t reserved; const void* packet; } event{1,0,nullptr};
    retro::environment(0x4d445301, &event);
}''')
    replace('src/libretro/platform/mp.cpp','void Platform::MP_End(void*) {\n    ZoneScopedN(TracyFunction);\n}',
            '''void Platform::MP_End(void*) {
    ZoneScopedN(TracyFunction);
    struct Event { uint32_t event; uint32_t reserved; const void* packet; } event{2,0,nullptr};
    retro::environment(0x4d445301, &event);
}''')
    replace('src/libretro/libretro.cpp','PUBLIC_SYMBOL void retro_init(void) {',
            '''extern "C" RETRO_API unsigned manic_ds_protocol_revision(void) { return 2; }
extern "C" RETRO_API bool manic_ds_wireless_identity(uint8_t* out) {
    const auto* console = MelonDsDs::Core.GetConsole();
    if (!out || !console) return false;
    std::memcpy(out, console->Wifi.GetMAC(), 6);
    return true;
}

PUBLIC_SYMBOL void retro_init(void) {''')
    for p,s in changes.items():p.write_text(s,encoding='utf-8',newline='\n')
    return list(changes)
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('checkout');a=p.parse_args()
    for file in patch(a.checkout):print(file)

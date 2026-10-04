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
    # Git on Windows may materialize text patches with CRLF. Normalize only
    # line endings before the exact public-source checksum guard.
    patch_bytes=compat.read_bytes().replace(b'\r\n',b'\n')
    if hashlib.sha256(patch_bytes).hexdigest()!=COMPAT_SHA256:raise ValueError('Manic compatibility patch checksum mismatch')
    subprocess.run(['git','-C',str(root),'apply','--check','-'],input=patch_bytes,check=True)
    subprocess.run(['git','-C',str(root),'apply','-'],input=patch_bytes,check=True)
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
    replace('src/libretro/net/mp.cpp','#include <ctime>',
            '#include "manic_receive_deadline.hpp"\n#include <thread>')
    replace('src/libretro/net/mp.cpp',
            '        for(std::clock_t start = std::clock(); std::clock() < (start + (RECV_TIMEOUT_MS * CLOCKS_PER_SEC / 1000));) {',
            '        manicds::ReceiveDeadline deadline(RECV_TIMEOUT_MS);\n        while(deadline.nextWaitMicros()) {')
    replace('src/libretro/net/mp.cpp',
            '''            if(!receivedPackets.empty()) {
                return NextPacket();
            }
        }''',
            '''            if(!receivedPackets.empty()) {
                return NextPacket();
            }
            struct Wait { uint32_t microseconds; uint32_t reserved; } wait{deadline.nextWaitMicros(),0};
            if(wait.microseconds && !retro::environment(0x4d445302, &wait))
                std::this_thread::sleep_for(std::chrono::microseconds(wait.microseconds));
        }''')
    replace('src/libretro/platform/mp.cpp','    _mpState.SetSendFn(nullptr);',
            '    _mpState.Reset();\n    _mpState.SetSendFn(nullptr);')
    replace('src/libretro/platform/mp.cpp',
            '    _mpState.PacketReceived(buf, len, client_id);',
            '''    // Filter before MpState chooses a reply host. Unrelated native
    // conversations may share a neighbourhood and reuse the same AID.
    if (!Console || !buf || len < HeaderSize + 36 || len > HeaderSize + 2048) return;
    const auto* wire = static_cast<const uint8_t*>(buf);
    const auto* frame = wire + HeaderSize;
    if (wire[9] == 2 && std::memcmp(frame + 22, Console->Wifi.GetBSSID(), 6)) return;
    if (wire[9] == 1 && std::memcmp(frame + 16, Console->Wifi.GetMAC(), 6)) return;
    _mpState.PacketReceived(buf, len, client_id);''')
    replace('src/libretro/platform/mp.cpp','#include <Platform.h>','#include <Platform.h>\n#include <cstring>')
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
            '''extern "C" RETRO_API unsigned manic_ds_protocol_revision(void) { return 5; }
extern "C" RETRO_API bool manic_ds_wireless_identity(uint8_t* out) {
    const auto* console = MelonDsDs::Core.GetConsole();
    if (!out || !console) return false;
    std::memcpy(out, console->Wifi.GetMAC(), 6);
    return true;
}
extern "C" RETRO_API bool manic_ds_firmware_identity_matches(void) {
    const auto* console = MelonDsDs::Core.GetConsole();
    return console && !std::memcmp(console->Wifi.GetMAC(), console->SPI.GetFirmware().GetHeader().MacAddr.data(), 6);
}

PUBLIC_SYMBOL void retro_init(void) {''')
    replace('src/libretro/config/console.cpp',
            '''        firmware.GetHeader().MacAddr = mac;
    }

    // fix touchscreen coords''',
            '''        firmware.GetHeader().MacAddr = mac;
    } else if (firmware.GetHeader().Identifier == melonDS::GENERATED_FIRMWARE_IDENTIFIER) {
        // Only a generated console with no explicit MAC uses the frontend's
        // persistent local identity. Native firmware files remain read-only.
        struct Generated { uint32_t version; uint8_t mac[6]; uint8_t reserved[2]; } request{1,{},{}};
        if (retro::environment(0x4d445303, &request) && request.version == 1 &&
            !request.reserved[0] && !request.reserved[1] && !(request.mac[0] & 1)) {
            bool nonzero = false; for (auto b : request.mac) nonzero |= b != 0;
            if (nonzero) std::memcpy(firmware.GetHeader().MacAddr.data(), request.mac, 6);
        }
    }

    // fix touchscreen coords''')
    for p,s in changes.items():p.write_text(s,encoding='utf-8',newline='\n')
    (root/'src/libretro/net/manic_receive_deadline.hpp').write_bytes((pathlib.Path(__file__).resolve().parents[1]/'Core/ReceiveDeadline.hpp').read_bytes())
    return list(changes)
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('checkout');a=p.parse_args()
    for file in patch(a.checkout):print(file)

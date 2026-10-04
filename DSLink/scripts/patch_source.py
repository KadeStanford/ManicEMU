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
    replace('src/libretro/net/mp.hpp','#include <libretro.h>','#include <libretro.h>\n#include "manic_reply_collector.hpp"')
    replace('src/libretro/net/mp.hpp','#include "manic_reply_collector.hpp"',
            '#include "manic_reply_collector.hpp"\n#include "manic_receive_deadline.hpp"\n#include "manic_diagnostics.hpp"')
    replace('src/libretro/net/mp.hpp','std::optional<Packet> NextPacketBlock() noexcept;',
            'std::optional<Packet> NextPacketBlock(uint32_t maximumWaitMicros = 25000) noexcept;')
    replace('src/libretro/net/mp.cpp','std::optional<Packet> MpState::NextPacketBlock() noexcept {',
            'std::optional<Packet> MpState::NextPacketBlock(uint32_t maximumWaitMicros) noexcept {')
    replace('src/libretro/core/core.hpp','std::optional<Packet> MpNextPacketBlock() noexcept;',
            'std::optional<Packet> MpNextPacketBlock(uint32_t maximumWaitMicros = 25000) noexcept;')
    replace('src/libretro/platform/mp.cpp','std::optional<MelonDsDs::Packet> MelonDsDs::CoreState::MpNextPacketBlock() noexcept {',
            'std::optional<MelonDsDs::Packet> MelonDsDs::CoreState::MpNextPacketBlock(uint32_t maximumWaitMicros) noexcept {')
    replace('src/libretro/platform/mp.cpp','return _mpState.NextPacketBlock();',
            'return _mpState.NextPacketBlock(maximumWaitMicros);')
    replace('src/libretro/net/mp.hpp','    std::vector<uint8_t> _data;',
            '    std::vector<uint8_t> _data;\n    uint8_t _sourceAid = 0;\n    uint16_t _sourceSlot = 65535;')
    replace('src/libretro/net/mp.hpp','    std::vector<uint8_t> ToBuf() const;',
            '''    uint8_t SourceAid() const noexcept { return _sourceAid; }
    void SetSourceAid(uint8_t aid) noexcept { _sourceAid = aid; }
    uint16_t SourceSlot() const noexcept { return _sourceSlot; }
    void SetSourceSlot(uint16_t slot) noexcept { _sourceSlot = slot; }
    std::vector<uint8_t> ToBuf() const;''')
    replace('src/libretro/net/mp.hpp','    bool IsReady() const noexcept;',
            '    bool IsReady() const noexcept;\n    uint32_t QueueDepth() const noexcept { return uint32_t(receivedPackets.size()); }')
    replace('src/libretro/net/mp.hpp','    void SendPacket(const Packet &p) noexcept;',
            '    void SendPacket(const Packet &p, uint16_t diagnosticNativeAid = 0) noexcept;')
    replace('src/libretro/net/mp.cpp','void MpState::SendPacket(const Packet &p) noexcept {',
            'void MpState::SendPacket(const Packet &p, uint16_t diagnosticNativeAid) noexcept {')
    replace('src/libretro/platform/mp.cpp','    _mpState.SendPacket(p);',
            '''    // Read-only diagnostic metadata. Native packet AID and bytes are
    // untouched, including intentionally unassigned/empty native replies.
    const uint16_t diagnosticNativeAid = Console ? Console->Wifi.Read(melonDS::Wifi::W_AIDLow) : 0;
    _mpState.SendPacket(p, diagnosticNativeAid);''')
    replace('src/libretro/core/core.hpp','    bool MpActive() const noexcept;',
            '    bool MpActive() const noexcept;\n    uint32_t MpQueueDepth() const noexcept { return _mpState.QueueDepth(); }')
    replace('src/libretro/net/mp.hpp','    std::queue<Packet> receivedPackets;',
            '    std::queue<Packet> receivedPackets;\n    manicds::ReplySources _replySources;')
    replace('src/libretro/net/mp.cpp','    _hostId.reset();','    _hostId.reset();\n    _replySources.reset();')
    replace('src/libretro/net/mp.cpp','    Packet p = Packet::parsePk(buf, len);',
            '''    Packet p = Packet::parsePk(buf, len);
    p.SetSourceSlot(client_id);
    if(p.PacketType() == Packet::Type::Reply)
        p.SetSourceAid(_replySources.associate(client_id,p.Aid(),p.Timestamp(),p.Length()));''')
    replace('src/libretro/net/mp.cpp','    receivedPackets.push(std::move(p));',
            '''    auto trace = manicds::packetDiagnostic(manicds::DiagnosticEvent::Receive,p,client_id,QueueDepth()+1);
    retro::environment(manicds::DiagnosticEnvironment,&trace);
    receivedPackets.push(std::move(p));''')
    replace('src/libretro/net/mp.cpp','        receivedPackets.pop();',
            '''        receivedPackets.pop();
        auto trace = manicds::packetDiagnostic(manicds::DiagnosticEvent::Dequeued,p,p.SourceSlot(),QueueDepth());
        retro::environment(manicds::DiagnosticEnvironment,&trace);''')
    replace('src/libretro/net/mp.cpp',
            '    _sendFn(RETRO_NETPACKET_UNSEQUENCED | RETRO_NETPACKET_UNRELIABLE | RETRO_NETPACKET_FLUSH_HINT, p.ToBuf().data(), p.Length() + HeaderSize, dest);',
            '''    auto trace = manicds::packetDiagnostic(manicds::DiagnosticEvent::Send,p,dest,QueueDepth());
    trace.sourceAid = diagnosticNativeAid;
    retro::environment(manicds::DiagnosticEnvironment,&trace);
    _sendFn(RETRO_NETPACKET_UNSEQUENCED | RETRO_NETPACKET_UNRELIABLE | RETRO_NETPACKET_FLUSH_HINT, p.ToBuf().data(), p.Length() + HeaderSize, dest);''')
    replace('src/libretro/net/mp.cpp','    _data((unsigned char*)data, (unsigned char*)data + len),','    _data(),')
    replace('src/libretro/net/mp.cpp','    _type(type){\n}',
            '    _type(type){\n    if(data && len) _data.assign((const uint8_t*)data,(const uint8_t*)data+len);\n}')
    replace('src/libretro/net/mp.cpp','    uint16_t dest = RETRO_NETPACKET_BROADCAST;',
            '''    uint16_t dest = RETRO_NETPACKET_BROADCAST;
    // Native association changes may reuse an AID within the same carrier.
    // A prior source/AID must never count an empty response for the new group.
    if(p.PacketType() == Packet::Type::Other && p.Length() >= 36) {
        const auto* frame = static_cast<const uint8_t*>(p.Data());
        unsigned subtype=frame[12] & 0xfc;
        if(subtype == 0x10 || subtype == 0xa0 || subtype == 0xc0) _replySources.reset();
    }
    // No radio header exists on this native no-payload response. It can only
    // belong to a command whose filtered host has already been established.
    if(p.PacketType() == Packet::Type::Reply && !p.Length() && !_hostId.has_value()) return;''')
    replace('src/libretro/net/mp.cpp','#include <ctime>',
            '#include "manic_receive_deadline.hpp"\n#include <thread>\n#include <algorithm>')
    replace('src/libretro/net/mp.cpp',
            '        for(std::clock_t start = std::clock(); std::clock() < (start + (RECV_TIMEOUT_MS * CLOCKS_PER_SEC / 1000));) {',
            '        manicds::ReceiveDeadline deadline(std::chrono::microseconds(std::min(maximumWaitMicros,uint32_t(RECV_TIMEOUT_MS * 1000))));\n        while(deadline.nextWaitMicros()) {')
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
    if (!Console || !buf || len < HeaderSize || len > HeaderSize + 2048) return;
    const auto* wire = static_cast<const uint8_t*>(buf);
    if(wire[9] > 2 || wire[8] >= 16 || (wire[9] == 1 && !wire[8] && len != HeaderSize)) return;
    auto signal = [](uint32_t number) {
        struct Event { uint32_t event; uint32_t reserved; const void* packet; } event{number,0,nullptr};
        retro::environment(0x4d445301, &event);
    };
    if (len == HeaderSize && wire[9] == 1 && wire[8] == 0) {
        signal(6);_mpState.PacketReceived(buf,len,client_id);return;
    }
    if (len < HeaderSize + 36) return;
    const auto* frame = wire + HeaderSize;
    if (wire[9] == 2 && std::memcmp(frame + 22, Console->Wifi.GetBSSID(), 6)) {signal(8);return;}
    if (wire[9] == 1 && std::memcmp(frame + 16, Console->Wifi.GetMAC(), 6)) {signal(9);return;}
    signal(wire[9] == 2 ? 5 : wire[9] == 1 ? 6 : 7);
    _mpState.PacketReceived(buf, len, client_id);''')
    replace('src/libretro/platform/mp.cpp','#include <Platform.h>','#include <Platform.h>\n#include <cstring>')
    replace('src/libretro/net/mp.cpp','    _timeoutCount++;',
            '''    // A packet may have arrived during the final wait while the frontend
    // wake-up was scheduled beyond the deadline. Check available data once,
    // without another wait, before reporting a native timeout.
    _sendFn(RETRO_NETPACKET_FLUSH_HINT, nullptr, 0, RETRO_NETPACKET_BROADCAST);
    _pollFn();
    if (!receivedPackets.empty()) return NextPacket();
    manicds::NativeDiagnostic trace;
    trace.event = uint32_t(manicds::DiagnosticEvent::Timeout); trace.depth = QueueDepth();
    retro::environment(manicds::DiagnosticEnvironment,&trace);
    struct Event { uint32_t event; uint32_t reserved; const void* packet; } event{4,0,nullptr};
    retro::environment(0x4d445301, &event);
    _timeoutCount++;''')
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
            '''extern "C" RETRO_API unsigned manic_ds_protocol_revision(void) { return 8; }
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
    libretro_path=root/'src/libretro/libretro.cpp'
    original_replies=libretro_path.read_text().split('u16 Platform::MP_RecvReplies(',1)[1]
    original_replies='u16 Platform::MP_RecvReplies('+original_replies.split('\n}',1)[0]+'\n}'
    reply_source=(pathlib.Path(__file__).resolve().parents[1]/'Core/ReceiveReplies.inc').read_text()
    replace('src/libretro/libretro.cpp',original_replies,reply_source[reply_source.index('u16 Platform::MP_RecvReplies('):].rstrip())
    replace('src/libretro/libretro.cpp',
            '''int Platform::MP_RecvHostPacket(u8* data, u64 * timestamp, void*) {
    std::optional<MelonDsDs::Packet> o_p = MelonDsDs::Core.MpNextPacketBlock();
    return DeconstructPacket(data, timestamp, o_p);
}''',
            '''int Platform::MP_RecvHostPacket(u8* data, u64 * timestamp, void*) {
    auto signal = [](uint32_t number) {
        struct Event { uint32_t event; uint32_t reserved; const void* packet; } event{number,0,nullptr};
        retro::environment(0x4d445301, &event);
    };
    signal(20);
    std::optional<MelonDsDs::Packet> o_p = MelonDsDs::Core.MpNextPacketBlock();
    manicds::NativeDiagnostic trace;
    trace.event = uint32_t(manicds::DiagnosticEvent::HostReceive);
    trace.depth = MelonDsDs::Core.MpQueueDepth();
    if (o_p) trace = manicds::packetDiagnostic(manicds::DiagnosticEvent::HostReceive,*o_p,o_p->SourceSlot(),trace.depth);
    retro::environment(manicds::DiagnosticEnvironment,&trace);
    const int length = DeconstructPacket(data, timestamp, o_p);
    if (!length) signal(22);
    signal(21);
    return length;
}''')
    replace('src/libretro/config/console.cpp',
            '''        firmware.GetHeader().MacAddr = mac;
    }

    // fix touchscreen coords''',
            '''        firmware.GetHeader().MacAddr = mac;
    }
    {
        // The frontend may own independent virtual hardware for local play.
        // Apply before boot for every firmware/configuration path so wireless
        // headers, Nintendo payloads and SDK caches see the same identity.
        // This custom request is supplied only for the nine local Pokemon
        // titles; other frontends/games retain the original MAC behavior.
        // The imported firmware file is not written here.
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
    (root/'src/libretro/net/manic_reply_collector.hpp').write_bytes((pathlib.Path(__file__).resolve().parents[1]/'Core/ReplyCollector.hpp').read_bytes())
    (root/'src/libretro/net/manic_diagnostics.hpp').write_bytes((pathlib.Path(__file__).resolve().parents[1]/'Core/Diagnostics.hpp').read_bytes())
    return list(changes)
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('checkout');a=p.parse_args()
    for file in patch(a.checkout):print(file)

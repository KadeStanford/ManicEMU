"""Isolated default-OFF native radio continuation experiment, public inputs."""
import hashlib,pathlib
def patch(root):
 root=pathlib.Path(root);here=pathlib.Path(__file__).resolve().parents[1]
 def edit(name,before,after):
  p=root/name;s=p.read_text()
  if s.count(before)!=1:raise ValueError('Async source guard: '+name)
  p.write_text(s.replace(before,after),encoding='utf-8',newline='\n')
 inc=(here/'Core/AsyncRadio.inc').read_text()
 edit('src/libretro/libretro.cpp','extern "C" RETRO_API unsigned manic_ds_protocol_revision(void) { return 8; }',inc+'''
extern "C" RETRO_API bool manic_ds_async_radio_enable(bool enabled) {
    manicds::CancelAsync();manicds::AsyncRadioEnabled=enabled;return true;
}
namespace melonDS::Platform { bool MP_IsAsync() {return manicds::AsyncRadioEnabled;} }
extern "C" RETRO_API unsigned manic_ds_protocol_revision(void) { return 8; }''')
 edit('src/libretro/libretro.cpp','u16 Platform::MP_RecvReplies(u8* packets, u64 timestamp, u16 aidmask, void*) {','u16 Platform::MP_RecvReplies(u8* packets, u64 timestamp, u16 aidmask, void*) {\n    if(manicds::AsyncRadioEnabled)return manicds::AsyncReceiveReplies(packets,timestamp,aidmask);')
 edit('src/libretro/libretro.cpp','''    signal(20);
    std::optional<MelonDsDs::Packet> o_p = MelonDsDs::Core.MpNextPacketBlock();''','''    std::optional<MelonDsDs::Packet> o_p;
    if(manicds::AsyncRadioEnabled){
        if(!MelonDsDs::Core.MpActive())return -1;
        o_p=manicds::AsyncReceiveHost();if(!o_p)return 0;
    }
    signal(20);
    if(!manicds::AsyncRadioEnabled)o_p=MelonDsDs::Core.MpNextPacketBlock();''')
 for marker in ('PUBLIC_SYMBOL void retro_unload_game(void) {','PUBLIC_SYMBOL void retro_reset(void) {','PUBLIC_SYMBOL bool retro_unserialize(const void *data, size_t size) {'):
  edit('src/libretro/libretro.cpp',marker,marker+'\n    manicds::CancelAsync();')
 edit('src/libretro/libretro.cpp','extern "C" void MelonDsDs::MpStopped() noexcept {','extern "C" void MelonDsDs::MpStopped() noexcept {\n    manicds::CancelAsync();')
 edit('src/libretro/net/mp.cpp','''    manicds::NativeDiagnostic trace;
    trace.event = uint32_t(manicds::DiagnosticEvent::Timeout);''','''    if(!maximumWaitMicros)return std::nullopt; // nonblocking poll, not a timeout
    manicds::NativeDiagnostic trace;
    trace.event = uint32_t(manicds::DiagnosticEvent::Timeout);''')
 helper=here/'scripts/patch_async_wifi.py';(root/'manic_async_wifi_patch.py').write_bytes(helper.read_bytes())
 edit('cmake/FetchDependencies.cmake','''    FetchContent_Declare(
        ${name}
        GIT_REPOSITORY''','''    set(manic_native_patch)
    if("${name}" STREQUAL "melonDS")
        find_program(MANIC_PATCH_PYTHON NAMES python3 python REQUIRED)
        set(manic_native_patch PATCH_COMMAND "${MANIC_PATCH_PYTHON}" "${CMAKE_SOURCE_DIR}/manic_async_wifi_patch.py" <SOURCE_DIR>)
    endif()
    FetchContent_Declare(
        ${name}
        ${manic_native_patch}
        GIT_REPOSITORY''')
 return ['src/libretro/libretro.cpp','src/libretro/net/mp.cpp','cmake/FetchDependencies.cmake','manic_async_wifi_patch.py']

// Optional bounded metadata from a verified native ARMul_State layout.
// No guest RAM, callbacks, thread suspension, pointers followed, or writes.
#pragma once
#include <mach/mach.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
typedef struct {
    uint32_t registers[16];
    uint32_t cpsr;
    uint64_t instruction_budget;
    uint32_t exclusive_tag;
    uint8_t exclusive_state;
} ManicInterpreterMetadata;
static bool ManicReadNativeBytes(uintptr_t address,void *output,size_t length){
    if(address<4096||address>UINTPTR_MAX-length)return false;
    vm_size_t copied=0;
    return vm_read_overwrite(mach_task_self(),address,length,(vm_address_t)output,&copied)==KERN_SUCCESS&&copied==length;
}
static bool ManicInterpreterPCSupported(uintptr_t offset){
    // X20=ARMul_State between its prologue MOV and epilogue restore. Also the
    // Read32 fast path before its slow-path MOV X20=MemorySystem.
    return (offset>=0x501d8c&&offset<=0x50fa0c)||
           (offset>=0x91c884&&offset<=0x91c8dc);
}
static bool ManicInterpreterRegistersSupported(uintptr_t offset,uintptr_t caller){
    return (offset>=0x501d8c&&offset<=0x50fa0c)||
        (offset>=0x91c884&&offset<=0x91c8dc&&caller>=0x501d8c&&caller<=0x50fa0c);
}
static bool ManicInterpreterLayoutSupported(uintptr_t core){
    // Actual preserved core GetPC/GetReg and interpreter X20 initialization.
    const uint32_t getPC[]={0xf9401408,0xb9404d00,0xd65f03c0};
    const uint32_t stateRegister=0xaa0003f4;
    uint32_t bytes[3],instruction=0;
    return core<=UINTPTR_MAX-0x501d8c&&
        ManicReadNativeBytes(core+0x4ffbfc,bytes,sizeof(bytes))&&
        !memcmp(bytes,getPC,sizeof(bytes))&&
        ManicReadNativeBytes(core+0x501d88,&instruction,sizeof(instruction))&&
        instruction==stateRegister;
}
static bool ManicReadInterpreterMetadata(uintptr_t offset,uintptr_t state,bool layoutSupported,ManicInterpreterMetadata *output){
    if(!layoutSupported||!ManicInterpreterPCSupported(offset)||state<4096||state>UINTPTR_MAX-0x3b0)return false;
    ManicInterpreterMetadata candidate={0};uint8_t exclusive[5];
    if(!ManicReadNativeBytes(state+0x10,candidate.registers,sizeof(candidate.registers))||
       !ManicReadNativeBytes(state+0x320,&candidate.cpsr,sizeof(candidate.cpsr))||
       !ManicReadNativeBytes(state+0x358,&candidate.instruction_budget,sizeof(candidate.instruction_budget))||
       !ManicReadNativeBytes(state+0x3a8,exclusive,sizeof(exclusive)))return false;
    memcpy(&candidate.exclusive_tag,exclusive,4);candidate.exclusive_state=exclusive[4];
    *output=candidate;return true;
}

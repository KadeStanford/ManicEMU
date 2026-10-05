#include "interpreter_metadata.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
int main(void){
    uint8_t *state=calloc(1,0x1000),*core=calloc(1,0x502000);
    assert(state&&core);
    uint32_t signature[]={0xf9401408,0xb9404d00,0xd65f03c0},mov=0xaa0003f4;
    memcpy(core+0x4ffbfc,signature,sizeof(signature));memcpy(core+0x501d88,&mov,4);
    assert(ManicInterpreterLayoutSupported((uintptr_t)core));
    core[0x4ffbfc]^=1;assert(!ManicInterpreterLayoutSupported((uintptr_t)core));core[0x4ffbfc]^=1;
    assert(!ManicInterpreterLayoutSupported(0));
    assert(ManicInterpreterRegistersSupported(0x91c8c4,0x50539c));
    assert(!ManicInterpreterRegistersSupported(0x91c8c4,0x9fc320));
    assert(!ManicInterpreterRegistersSupported(0x91c918,0x50539c));
    assert(!ManicInterpreterPCSupported(0x501d88));
    assert(!ManicInterpreterPCSupported(0x50fa14));
    uint32_t registers[16];for(unsigned i=0;i<16;i++)registers[i]=0x100000+i*4;
    uint32_t cpsr=0x20000010,tag=0x12345678;uint64_t budget=4567;
    memcpy(state+0x10,registers,64);memcpy(state+0x320,&cpsr,4);
    memcpy(state+0x358,&budget,8);memcpy(state+0x3a8,&tag,4);state[0x3ac]=1;
    ManicInterpreterMetadata metadata={0};
    assert(ManicReadInterpreterMetadata(0x505374,(uintptr_t)state,true,&metadata));
    assert(!memcmp(metadata.registers,registers,64)&&metadata.cpsr==cpsr&&metadata.instruction_budget==budget&&metadata.exclusive_tag==tag&&metadata.exclusive_state==1);
    ManicInterpreterMetadata original=metadata;
    assert(!ManicReadInterpreterMetadata(0x505374,(uintptr_t)state,false,&metadata));
    assert(!ManicReadInterpreterMetadata(0x1,(uintptr_t)state,true,&metadata));
    assert(!ManicReadInterpreterMetadata(0x505374,0,true,&metadata));
    assert(!ManicReadInterpreterMetadata(0x505374,UINTPTR_MAX-4,true,&metadata));
    assert(!ManicReadInterpreterMetadata(0x505374,4096,true,&metadata));
    assert(!memcmp(&metadata,&original,sizeof(metadata)));
    free(state);free(core);
    puts("{\"layout_fingerprint_checked\":true,\"pc_and_caller_gates_passed\":true,\"bounded_native_fields_read\":true,\"invalid_reads_leave_output_unchanged\":true,\"guest_ram_read\":false,\"synthetic_cpu_state_only\":true}");
    return 0;
}

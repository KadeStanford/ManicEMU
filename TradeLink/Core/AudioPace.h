// SPDX-License-Identifier: AGPL-3.0-or-later
#ifndef MANIC_AUDIO_PACE_H
#define MANIC_AUDIO_PACE_H
#include <stdint.h>
#include <stddef.h>
typedef struct { int16_t tail[2]; int pending; } MTAudioPace;
// In-place stereo 2:1 box downsample. Carry the odd frame across calls so
// accelerated audio cannot slowly accumulate an extra sample per game frame.
// Normal gameplay returns the original buffer unchanged.
static inline size_t MT_audio_pace(MTAudioPace *pace,int16_t *samples,size_t frames,unsigned rate) {
    if(rate!=2){pace->pending=0;return frames;}
    size_t input=0,output=0;
    if(pace->pending&&frames){
        for(unsigned c=0;c<2;c++)samples[c]=(int16_t)(((int32_t)pace->tail[c]+samples[c])/2);
        input=1;output=1;pace->pending=0;
    }
    while(input+1<frames){
        for(unsigned c=0;c<2;c++)samples[2*output+c]=(int16_t)(((int32_t)samples[2*input+c]+samples[2*(input+1)+c])/2);
        input+=2;output++;
    }
    if(input<frames){pace->tail[0]=samples[2*input];pace->tail[1]=samples[2*input+1];pace->pending=1;}
    return output;
}
#endif

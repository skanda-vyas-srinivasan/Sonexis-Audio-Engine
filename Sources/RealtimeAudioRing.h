#ifndef RealtimeAudioRing_h
#define RealtimeAudioRing_h

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct SonexisAudioRingBuffer SonexisAudioRingBuffer;

SonexisAudioRingBuffer *SonexisAudioRingBufferCreate(uint32_t capacityFrames, uint32_t channels);
void SonexisAudioRingBufferDestroy(SonexisAudioRingBuffer *ringBuffer);

uint32_t SonexisAudioRingBufferWriteFromAudioBufferList(
    SonexisAudioRingBuffer *ringBuffer,
    const AudioBufferList *inputData,
    float gain
);

uint32_t SonexisAudioRingBufferReadToAudioBufferList(
    SonexisAudioRingBuffer *ringBuffer,
    AudioBufferList *outputData
);

uint32_t SonexisAudioRingBufferGetFillFrames(SonexisAudioRingBuffer *ringBuffer);
uint64_t SonexisAudioRingBufferGetDroppedFrames(SonexisAudioRingBuffer *ringBuffer);
uint64_t SonexisAudioRingBufferGetUnderflowFrames(SonexisAudioRingBuffer *ringBuffer);
uint64_t SonexisAudioRingBufferGetWrittenFrames(SonexisAudioRingBuffer *ringBuffer);
uint64_t SonexisAudioRingBufferGetReadFrames(SonexisAudioRingBuffer *ringBuffer);
uint32_t SonexisAudioRingBufferGetLastInputPeakPPM(SonexisAudioRingBuffer *ringBuffer);

#endif

#include "RealtimeAudioRing.h"

#include <stdatomic.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

struct SonexisAudioRingBuffer {
    float *samples;
    uint32_t capacityFrames;
    uint32_t channels;
    atomic_uint writeFrame;
    atomic_uint readFrame;
    atomic_ullong droppedFrames;
    atomic_ullong underflowFrames;
    atomic_ullong writtenFrames;
    atomic_ullong readFrames;
    atomic_uint lastInputPeakPPM;
};

static uint32_t minimumFrameCountInAudioBufferList(const AudioBufferList *bufferList) {
    if (bufferList == NULL || bufferList->mNumberBuffers == 0) {
        return 0;
    }

    uint32_t result = UINT32_MAX;
    bool foundBuffer = false;

    for (uint32_t bufferIndex = 0; bufferIndex < bufferList->mNumberBuffers; ++bufferIndex) {
        const AudioBuffer *buffer = &bufferList->mBuffers[bufferIndex];
        if (buffer->mData == NULL || buffer->mDataByteSize == 0 || buffer->mNumberChannels == 0) {
            continue;
        }

        uint32_t bytesPerFrame = (uint32_t)sizeof(float) * buffer->mNumberChannels;
        uint32_t frames = buffer->mDataByteSize / bytesPerFrame;
        if (frames < result) {
            result = frames;
        }
        foundBuffer = true;
    }

    return foundBuffer ? result : 0;
}

static void zeroAudioBufferList(AudioBufferList *bufferList) {
    if (bufferList == NULL) {
        return;
    }

    for (uint32_t bufferIndex = 0; bufferIndex < bufferList->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &bufferList->mBuffers[bufferIndex];
        if (buffer->mData != NULL && buffer->mDataByteSize > 0) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

SonexisAudioRingBuffer *SonexisAudioRingBufferCreate(uint32_t capacityFrames, uint32_t channels) {
    if (capacityFrames == 0 || channels == 0) {
        return NULL;
    }

    SonexisAudioRingBuffer *ringBuffer = calloc(1, sizeof(SonexisAudioRingBuffer));
    if (ringBuffer == NULL) {
        return NULL;
    }

    ringBuffer->samples = calloc((size_t)capacityFrames * channels, sizeof(float));
    if (ringBuffer->samples == NULL) {
        free(ringBuffer);
        return NULL;
    }

    ringBuffer->capacityFrames = capacityFrames;
    ringBuffer->channels = channels;
    atomic_init(&ringBuffer->writeFrame, 0);
    atomic_init(&ringBuffer->readFrame, 0);
    atomic_init(&ringBuffer->droppedFrames, 0);
    atomic_init(&ringBuffer->underflowFrames, 0);
    atomic_init(&ringBuffer->writtenFrames, 0);
    atomic_init(&ringBuffer->readFrames, 0);
    atomic_init(&ringBuffer->lastInputPeakPPM, 0);

    return ringBuffer;
}

void SonexisAudioRingBufferDestroy(SonexisAudioRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return;
    }

    free(ringBuffer->samples);
    free(ringBuffer);
}

uint32_t SonexisAudioRingBufferWriteFromAudioBufferList(
    SonexisAudioRingBuffer *ringBuffer,
    const AudioBufferList *inputData,
    float gain
) {
    if (ringBuffer == NULL || inputData == NULL) {
        return 0;
    }

    uint32_t incomingFrames = minimumFrameCountInAudioBufferList(inputData);
    if (incomingFrames == 0) {
        return 0;
    }

    uint32_t writeFrame = atomic_load_explicit(&ringBuffer->writeFrame, memory_order_relaxed);
    uint32_t readFrame = atomic_load_explicit(&ringBuffer->readFrame, memory_order_acquire);
    uint32_t readableFrames = writeFrame - readFrame;
    uint32_t writableFrames = ringBuffer->capacityFrames - readableFrames;
    uint32_t framesToWrite = incomingFrames < writableFrames ? incomingFrames : writableFrames;

    if (framesToWrite < incomingFrames) {
        atomic_fetch_add_explicit(
            &ringBuffer->droppedFrames,
            (unsigned long long)(incomingFrames - framesToWrite),
            memory_order_relaxed
        );
    }

    float peak = 0.0f;

    for (uint32_t frame = 0; frame < framesToWrite; ++frame) {
        uint32_t outputFrame = (writeFrame + frame) % ringBuffer->capacityFrames;
        uint32_t outputBase = outputFrame * ringBuffer->channels;
        uint32_t outputChannel = 0;

        for (uint32_t bufferIndex = 0; bufferIndex < inputData->mNumberBuffers; ++bufferIndex) {
            const AudioBuffer *buffer = &inputData->mBuffers[bufferIndex];
            if (buffer->mData == NULL || buffer->mNumberChannels == 0) {
                continue;
            }

            const float *samples = (const float *)buffer->mData;
            uint32_t bufferChannels = buffer->mNumberChannels;

            for (uint32_t channel = 0; channel < bufferChannels; ++channel) {
                if (outputChannel >= ringBuffer->channels) {
                    break;
                }

                float inputSample = samples[(frame * bufferChannels) + channel];
                float absoluteSample = fabsf(inputSample);
                if (absoluteSample > peak) {
                    peak = absoluteSample;
                }
                ringBuffer->samples[outputBase + outputChannel] = inputSample * gain;
                outputChannel += 1;
            }
        }

        while (outputChannel < ringBuffer->channels) {
            ringBuffer->samples[outputBase + outputChannel] = 0.0f;
            outputChannel += 1;
        }
    }

    uint32_t peakPPM = (uint32_t)fminf(peak * 1000000.0f, 1000000.0f);
    atomic_store_explicit(&ringBuffer->lastInputPeakPPM, peakPPM, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &ringBuffer->writtenFrames,
        (unsigned long long)framesToWrite,
        memory_order_relaxed
    );
    atomic_store_explicit(&ringBuffer->writeFrame, writeFrame + framesToWrite, memory_order_release);
    return framesToWrite;
}

uint32_t SonexisAudioRingBufferReadToAudioBufferList(
    SonexisAudioRingBuffer *ringBuffer,
    AudioBufferList *outputData
) {
    if (ringBuffer == NULL || outputData == NULL) {
        return 0;
    }

    uint32_t requestedFrames = minimumFrameCountInAudioBufferList(outputData);
    if (requestedFrames == 0) {
        zeroAudioBufferList(outputData);
        return 0;
    }

    zeroAudioBufferList(outputData);

    uint32_t writeFrame = atomic_load_explicit(&ringBuffer->writeFrame, memory_order_acquire);
    uint32_t readFrame = atomic_load_explicit(&ringBuffer->readFrame, memory_order_relaxed);
    uint32_t readableFrames = writeFrame - readFrame;
    uint32_t framesToRead = requestedFrames < readableFrames ? requestedFrames : readableFrames;

    if (framesToRead < requestedFrames) {
        atomic_fetch_add_explicit(
            &ringBuffer->underflowFrames,
            (unsigned long long)(requestedFrames - framesToRead),
            memory_order_relaxed
        );
    }

    for (uint32_t frame = 0; frame < framesToRead; ++frame) {
        uint32_t inputFrame = (readFrame + frame) % ringBuffer->capacityFrames;
        uint32_t inputBase = inputFrame * ringBuffer->channels;
        uint32_t inputChannel = 0;

        for (uint32_t bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; ++bufferIndex) {
            AudioBuffer *buffer = &outputData->mBuffers[bufferIndex];
            if (buffer->mData == NULL || buffer->mNumberChannels == 0) {
                continue;
            }

            float *samples = (float *)buffer->mData;
            uint32_t bufferChannels = buffer->mNumberChannels;

            for (uint32_t channel = 0; channel < bufferChannels; ++channel) {
                if (inputChannel >= ringBuffer->channels) {
                    break;
                }

                samples[(frame * bufferChannels) + channel] =
                    ringBuffer->samples[inputBase + inputChannel];
                inputChannel += 1;
            }
        }
    }

    atomic_fetch_add_explicit(
        &ringBuffer->readFrames,
        (unsigned long long)framesToRead,
        memory_order_relaxed
    );
    atomic_store_explicit(&ringBuffer->readFrame, readFrame + framesToRead, memory_order_release);
    return framesToRead;
}

uint32_t SonexisAudioRingBufferGetFillFrames(SonexisAudioRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return 0;
    }

    uint32_t writeFrame = atomic_load_explicit(&ringBuffer->writeFrame, memory_order_acquire);
    uint32_t readFrame = atomic_load_explicit(&ringBuffer->readFrame, memory_order_acquire);
    return writeFrame - readFrame;
}

uint64_t SonexisAudioRingBufferGetDroppedFrames(SonexisAudioRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return 0;
    }

    return atomic_load_explicit(&ringBuffer->droppedFrames, memory_order_relaxed);
}

uint64_t SonexisAudioRingBufferGetUnderflowFrames(SonexisAudioRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return 0;
    }

    return atomic_load_explicit(&ringBuffer->underflowFrames, memory_order_relaxed);
}

uint64_t SonexisAudioRingBufferGetWrittenFrames(SonexisAudioRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return 0;
    }

    return atomic_load_explicit(&ringBuffer->writtenFrames, memory_order_relaxed);
}

uint64_t SonexisAudioRingBufferGetReadFrames(SonexisAudioRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return 0;
    }

    return atomic_load_explicit(&ringBuffer->readFrames, memory_order_relaxed);
}

uint32_t SonexisAudioRingBufferGetLastInputPeakPPM(SonexisAudioRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return 0;
    }

    return atomic_load_explicit(&ringBuffer->lastInputPeakPPM, memory_order_relaxed);
}

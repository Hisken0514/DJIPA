#include "AudioCore.h"
#include "Effects.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct PAEngine {
    UInt32 inOffset, inCount, outOffset, outCount;

    _Atomic float gain, ceiling;
    _Atomic bool muted;
    _Atomic float inPeak, outPeak;
    _Atomic bool limited;
    _Atomic unsigned long long callbacks;

    /* 只在音訊執行緒使用 */
    float smoothGain;   /* 平滑後的音量，避免爆音 */
    float limiterGain;  /* 限幅器目前的增益 (0..1] */
    float rampCoef, releaseCoef;

    AudioObjectID device;
    AudioDeviceIOProcID procID;
    Effects fx;
};

PAEngine *pa_create(UInt32 inOffset, UInt32 inCount, UInt32 outOffset, UInt32 outCount,
                    double sampleRate) {
    PAEngine *e = calloc(1, sizeof(PAEngine));
    if (!e) return NULL;
    e->inOffset = inOffset;
    e->inCount = inCount;
    e->outOffset = outOffset;
    e->outCount = outCount;
    atomic_init(&e->gain, 0.0f);
    atomic_init(&e->ceiling, 0.5f);
    atomic_init(&e->muted, false);
    e->smoothGain = 0.0f; /* 從靜音淡入 */
    e->limiterGain = 1.0f;
    e->rampCoef = (float)(1.0 - exp(-1.0 / (0.030 * sampleRate)));    /* 30 ms */
    e->releaseCoef = (float)(1.0 - exp(-1.0 / (0.250 * sampleRate))); /* 250 ms */
    fx_init(&e->fx, sampleRate);
    return e;
}

void pa_set_highpass(PAEngine *e, bool on) { atomic_store(&e->fx.hpOn, on); }
void pa_set_gate(PAEngine *e, bool on, float threshold) {
    atomic_store(&e->fx.gateThreshold, threshold);
    atomic_store(&e->fx.gateOn, on);
}
void pa_set_howl(PAEngine *e, bool on) {
    atomic_store(&e->fx.howlOn, on);
    if (!on) fx_clear_notches(&e->fx);
}
bool pa_take_gate_open(PAEngine *e) { return atomic_exchange(&e->fx.gateOpened, false); }
void pa_analyze(PAEngine *e) {
    if (!atomic_load(&e->muted)) fx_analyze(&e->fx);
}
int pa_notch_count(void) { return FX_NOTCHES; }
float pa_notch_freq(PAEngine *e, int i) {
    return (i >= 0 && i < FX_NOTCHES) ? atomic_load(&e->fx.notchFreq[i]) : 0.0f;
}
void pa_clear_notches(PAEngine *e) { fx_clear_notches(&e->fx); }

void pa_set_gain(PAEngine *e, float v) { atomic_store(&e->gain, v); }
void pa_set_ceiling(PAEngine *e, float v) { atomic_store(&e->ceiling, v); }
void pa_set_muted(PAEngine *e, bool v) { atomic_store(&e->muted, v); }
float pa_take_input_peak(PAEngine *e) { return atomic_exchange(&e->inPeak, 0.0f); }
float pa_take_output_peak(PAEngine *e) { return atomic_exchange(&e->outPeak, 0.0f); }
bool pa_take_limited(PAEngine *e) { return atomic_exchange(&e->limited, false); }
unsigned long long pa_callback_count(PAEngine *e) { return atomic_load(&e->callbacks); }

/* 找出第 channel 個聲道（跨所有 buffer 編號）。 */
static float *channel_ptr(const AudioBufferList *list, UInt32 channel,
                          UInt32 *stride, UInt32 *frames) {
    for (UInt32 b = 0; b < list->mNumberBuffers; b++) {
        const AudioBuffer *buf = &list->mBuffers[b];
        UInt32 n = buf->mNumberChannels;
        if (channel < n) {
            if (!buf->mData) return NULL;
            *stride = n;
            *frames = buf->mDataByteSize / (UInt32)(sizeof(float) * n);
            return (float *)buf->mData + channel;
        }
        channel -= n;
    }
    return NULL;
}

#define MAX_CH 32

void pa_process(PAEngine *e, const AudioBufferList *in, AudioBufferList *out) {
    if (!out) return;
    for (UInt32 b = 0; b < out->mNumberBuffers; b++)
        if (out->mBuffers[b].mData)
            memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);

    const float *src[MAX_CH];
    UInt32 srcStride[MAX_CH], nSrc = 0, frames = 0;
    float *dst[MAX_CH];
    UInt32 dstStride[MAX_CH], nDst = 0, outFrames = 0;

    for (UInt32 c = 0; in && c < e->inCount && nSrc < MAX_CH; c++) {
        UInt32 s, f;
        float *p = channel_ptr(in, e->inOffset + c, &s, &f);
        if (!p) continue;
        src[nSrc] = p;
        srcStride[nSrc++] = s;
        frames = (nSrc == 1 || f < frames) ? f : frames;
    }
    for (UInt32 c = 0; c < e->outCount && nDst < MAX_CH; c++) {
        UInt32 s, f;
        float *p = channel_ptr(out, e->outOffset + c, &s, &f);
        if (!p) continue;
        dst[nDst] = p;
        dstStride[nDst++] = s;
        outFrames = (nDst == 1 || f < outFrames) ? f : outFrames;
    }
    atomic_fetch_add(&e->callbacks, 1);
    if (!nSrc || !nDst) return;
    if (outFrames < frames) frames = outFrames;

    const float target = atomic_load(&e->muted) ? 0.0f : atomic_load(&e->gain);
    const float ceiling = atomic_load(&e->ceiling);
    float inPeak = 0.0f, outPeak = 0.0f;
    bool limited = false;

    for (UInt32 i = 0; i < frames; i++) {
        float mono = 0.0f;
        for (UInt32 c = 0; c < nSrc; c++) mono += src[c][i * srcStride[c]];
        mono /= (float)nSrc;
        if (!isfinite(mono)) mono = 0.0f;
        inPeak = fmaxf(inPeak, fabsf(mono));

        mono = fx_process(&e->fx, mono);

        e->smoothGain += e->rampCoef * (target - e->smoothGain);
        float v = mono * e->smoothGain;

        /* 峰值限幅：超過上限立刻壓下，之後緩慢放開 */
        float mag = fabsf(v);
        float needed = (mag > ceiling) ? ceiling / mag : 1.0f;
        if (needed < e->limiterGain) {
            e->limiterGain = needed;
            limited = true;
        } else {
            e->limiterGain += e->releaseCoef * (needed - e->limiterGain);
        }
        v *= e->limiterGain;
        v = fmaxf(-ceiling, fminf(ceiling, v));
        outPeak = fmaxf(outPeak, fabsf(v));

        /* 單聲道麥克風送到前兩個輸出聲道（左右） */
        for (UInt32 c = 0; c < nDst && c < 2; c++) dst[c][i * dstStride[c]] = v;
    }

    if (inPeak > atomic_load(&e->inPeak)) atomic_store(&e->inPeak, inPeak);
    if (outPeak > atomic_load(&e->outPeak)) atomic_store(&e->outPeak, outPeak);
    if (limited) atomic_store(&e->limited, true);
}

static OSStatus io_proc(AudioObjectID device, const AudioTimeStamp *now,
                        const AudioBufferList *in, const AudioTimeStamp *inTime,
                        AudioBufferList *out, const AudioTimeStamp *outTime, void *ctx) {
    (void)device; (void)now; (void)inTime; (void)outTime;
    pa_process((PAEngine *)ctx, in, out);
    return noErr;
}

OSStatus pa_start(PAEngine *e, AudioObjectID device) {
    OSStatus err = AudioDeviceCreateIOProcID(device, io_proc, e, &e->procID);
    if (err != noErr) return err;
    e->device = device;
    err = AudioDeviceStart(device, e->procID);
    if (err != noErr) pa_stop(e);
    return err;
}

void pa_stop(PAEngine *e) {
    if (!e->procID) return;
    AudioDeviceStop(e->device, e->procID);
    AudioDeviceDestroyIOProcID(e->device, e->procID);
    e->procID = NULL;
}

void pa_destroy(PAEngine *e) {
    if (!e) return;
    pa_stop(e);
    free(e);
}

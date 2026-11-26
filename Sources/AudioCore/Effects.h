/* 低頻切除、噪音閘門、自動嘯叫抑制 */
#ifndef EFFECTS_H
#define EFFECTS_H

#include <stdatomic.h>
#include <stdbool.h>

#define FX_FFT 4096
#define FX_NOTCHES 6

typedef struct { float b0, b1, b2, a1, a2, z1, z2; } Biquad;

typedef struct {
    float rate;

    /* 控制參數（跨執行緒） */
    _Atomic bool hpOn, gateOn, howlOn;
    _Atomic float gateThreshold;              /* 線性振幅 */
    _Atomic float notchFreq[FX_NOTCHES];      /* 0 = 未使用 */
    _Atomic float notchDB[FX_NOTCHES];
    _Atomic bool gateOpened;

    /* 只在音訊執行緒使用 */
    Biquad hp;
    Biquad notch[FX_NOTCHES];
    float curFreq[FX_NOTCHES], curDB[FX_NOTCHES];
    float envelope, gateGain;
    int hold;
    float envRelease, gateAttack, gateRelease;

    /* 音訊執行緒寫入、分析執行緒讀取 */
    _Atomic float ring[FX_FFT];
    _Atomic unsigned long long written;

    /* 只在分析執行緒使用 */
    float candFreq, candPower;
    int candCount;
    int nextSlot;
    unsigned long long analyzed;
} Effects;

void fx_init(Effects *fx, double sampleRate);
float fx_process(Effects *fx, float x);
void fx_analyze(Effects *fx);
void fx_clear_notches(Effects *fx);

#endif

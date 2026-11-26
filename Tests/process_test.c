/* 離線測試訊號處理，不會發出聲音。執行 ./test.sh */
#include "AudioCore.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define N 4800

static float in[N * 2], spare[N * 2], out[N * 2];

/* 跑一次處理，回傳最後 100 個取樣的左聲道峰值，並檢查全段不超過上限 */
static float run(PAEngine *e, float amplitude, float ceiling) {
    for (int i = 0; i < N; i++) in[2 * i] = in[2 * i + 1] = (i % 2 ? amplitude : -amplitude);
    AudioBufferList il = {1, {{2, sizeof in, in}}};
    /* 兩個輸出 buffer：第一個模擬麥克風自己的輸出，應保持靜音 */
    struct { UInt32 n; AudioBuffer b[2]; } ol = {2, {{2, sizeof spare, spare}, {2, sizeof out, out}}};
    spare[0] = 1.0f;
    pa_process(e, &il, (AudioBufferList *)&ol);
    float tail = 0;
    for (int i = 0; i < N * 2; i++) {
        assert(fabsf(out[i]) <= ceiling + 1e-6f);
        assert(spare[i] == 0.0f);
    }
    for (int i = N - 100; i < N; i++) {
        assert(out[2 * i] == out[2 * i + 1]); /* 左右相同 */
        tail = fmaxf(tail, fabsf(out[2 * i]));
    }
    return tail;
}

/* 餵一段訊號給效果器，每 50 ms 分析一次，回傳最後 0.1 秒的輸出峰值 */
typedef float (*Signal)(int);
static float sine(float hz, float amp, int i) { return amp * sinf(6.2831853f * hz * i / 48000); }
static float howlTone(int i) { return sine(1234, 0.2f, i); }
static float voiceLike(int i) { return sine(220, 0.2f, i) + sine(440, 0.12f, i) + sine(660, 0.08f, i); }
static float rumble(int i) { return sine(30, 0.2f, i); }
static float speechTone(int i) { return sine(1000, 0.2f, i); }
static float quiet(int i) { return sine(1000, 0.001f, i); }
static float noise(int i) { (void)i; return ((float)rand() / RAND_MAX - 0.5f) * 0.3f; }

static float feed(PAEngine *e, Signal s, float seconds) {
    static float mic[480 * 2], spk[480 * 2];
    int blocks = (int)(seconds * 100);
    float tail = 0;
    for (int b = 0; b < blocks; b++) {
        for (int i = 0; i < 480; i++) mic[2 * i] = mic[2 * i + 1] = s(b * 480 + i);
        AudioBufferList il = {1, {{2, sizeof mic, mic}}}, ol = {1, {{2, sizeof spk, spk}}};
        pa_process(e, &il, &ol);
        if (b % 5 == 4) pa_analyze(e);
        if (b >= blocks - 10)
            for (int i = 0; i < 960; i++) tail = fmaxf(tail, fabsf(spk[i]));
    }
    return tail;
}

static PAEngine *engine(void) {
    PAEngine *e = pa_create(0, 2, 0, 2, 48000);
    pa_set_gain(e, 1.0f);
    pa_set_ceiling(e, 0.9f);
    return e;
}

static int notches(PAEngine *e) {
    int n = 0;
    for (int i = 0; i < pa_notch_count(); i++) n += pa_notch_freq(e, i) > 0;
    return n;
}

static void test_effects(void) {
    PAEngine *e = engine();
    pa_set_highpass(e, true);
    assert(feed(e, rumble, 1) < 0.03f);               /* 30 Hz 大幅衰減 */
    assert(fabsf(feed(e, speechTone, 1) - 0.2f) < 0.01f); /* 1 kHz 通過 */
    pa_destroy(e);

    e = engine();
    pa_set_gate(e, true, 0.01f);
    assert(feed(e, quiet, 2) < 0.0001f);              /* 低於門檻：衰減 24 dB */
    assert(feed(e, speechTone, 0.5f) > 0.19f);        /* 講話：打開 */
    assert(feed(e, quiet, 2) < 0.0001f);              /* 停止後關閉 */
    pa_destroy(e);

    e = engine();
    pa_set_howl(e, true);
    feed(e, voiceLike, 3);
    assert(notches(e) == 0);                          /* 有泛音的聲音不處理 */
    feed(e, noise, 3);
    assert(notches(e) == 0);
    float after = feed(e, howlTone, 3);
    assert(notches(e) >= 1);
    assert(fabsf(pa_notch_freq(e, 0) - 1234) < 5);
    printf("嘯叫偵測 %.1f Hz，衰減後峰值 %.3f（原 0.200）\n", pa_notch_freq(e, 0), after);
    assert(after < 0.05f);                            /* 至少 -12 dB */
    pa_clear_notches(e);
    assert(notches(e) == 0);
    pa_set_howl(e, false);
    feed(e, howlTone, 2);
    assert(notches(e) == 0);
    pa_destroy(e);
}

int main(void) {
    test_effects();
    PAEngine *e = pa_create(0, 2, 2, 2, 48000);
    pa_set_gain(e, 1.0f);
    pa_set_ceiling(e, 0.5f);

    run(e, 0.25f, 0.5f);
    assert(fabsf(run(e, 0.25f, 0.5f) - 0.25f) < 0.001f); /* 低於上限：原音量 */
    assert(!pa_take_limited(e));

    assert(run(e, 1.0f, 0.5f) <= 0.5f); /* 突然大聲：不超過上限 */
    assert(pa_take_limited(e));

    pa_set_gain(e, 8.0f);
    run(e, 1.0f, 0.5f);

    pa_set_muted(e, true);
    run(e, 1.0f, 0.5f);
    run(e, 1.0f, 0.5f);
    run(e, 1.0f, 0.5f);
    assert(run(e, 1.0f, 0.5f) < 0.001f); /* 淡出 0.4 秒後應靜音 */

    pa_destroy(e);
    puts("全部通過");
    return 0;
}

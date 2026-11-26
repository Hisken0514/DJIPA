#include "Effects.h"
#include <math.h>

#define PI_F 3.14159265358979323846f
#define HP_HZ 100.0f
#define GATE_FLOOR 0.063f       /* 關閉時 -24 dB，避免完全切斷 */
#define NOTCH_Q 20.0f
#define NOTCH_FIRST_DB (-18.0f)
#define NOTCH_DEEP_DB (-30.0f)
#define HOWL_ROUNDS 8           /* 連續幾次分析都成立才判定（約 0.4 秒） */

#define load(p) atomic_load_explicit(p, memory_order_relaxed)
#define store(p, v) atomic_store_explicit(p, v, memory_order_relaxed)

static void biquad_set(Biquad *q, float b0, float b1, float b2, float a0, float a1, float a2) {
    q->b0 = b0 / a0; q->b1 = b1 / a0; q->b2 = b2 / a0;
    q->a1 = a1 / a0; q->a2 = a2 / a0;
}

static float biquad_run(Biquad *q, float x) {
    float y = q->b0 * x + q->z1;
    q->z1 = q->b1 * x - q->a1 * y + q->z2;
    q->z2 = q->b2 * x - q->a2 * y;
    return y;
}

static void highpass(Biquad *q, float rate) {
    float w = 2 * PI_F * HP_HZ / rate, c = cosf(w), alpha = sinf(w) / (2 * 0.7071f);
    biquad_set(q, (1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha);
}

/* 窄頻衰減（peaking EQ，負增益） */
static void notch(Biquad *q, float rate, float freq, float db) {
    float w = 2 * PI_F * freq / rate, c = cosf(w), alpha = sinf(w) / (2 * NOTCH_Q);
    float A = powf(10, db / 40);
    biquad_set(q, 1 + alpha * A, -2 * c, 1 - alpha * A, 1 + alpha / A, -2 * c, 1 - alpha / A);
}

void fx_init(Effects *fx, double sampleRate) {
    fx->rate = (float)sampleRate;
    highpass(&fx->hp, fx->rate);
    store(&fx->gateThreshold, 0.0018f);
    fx->gateGain = 1.0f;
    fx->envRelease = expf(-1.0f / (0.050f * fx->rate));
    fx->gateAttack = 1 - expf(-1.0f / (0.003f * fx->rate));
    fx->gateRelease = 1 - expf(-1.0f / (0.150f * fx->rate));
}

float fx_process(Effects *fx, float x) {
    /* 1. 低頻切除 */
    float hp = biquad_run(&fx->hp, x);
    if (load(&fx->hpOn)) x = hp;

    /* 2. 嘯叫陷波 */
    for (int i = 0; i < FX_NOTCHES; i++) {
        float f = load(&fx->notchFreq[i]), db = load(&fx->notchDB[i]);
        if (f != fx->curFreq[i] || db != fx->curDB[i]) {
            if (f != fx->curFreq[i]) fx->notch[i].z1 = fx->notch[i].z2 = 0;
            fx->curFreq[i] = f;
            fx->curDB[i] = db;
            if (f > 0) notch(&fx->notch[i], fx->rate, f, db);
        }
        if (f > 0) x = biquad_run(&fx->notch[i], x);
    }

    /* 3. 噪音閘門：高於門檻打開，低於門檻 4 dB 以下並過了保持時間才關 */
    float mag = fabsf(x);
    fx->envelope = mag > fx->envelope ? mag : fx->envelope * fx->envRelease;
    float target = 1.0f;
    if (load(&fx->gateOn)) {
        float th = load(&fx->gateThreshold);
        if (fx->envelope >= th || (fx->hold > 0 && fx->envelope >= th * 0.63f))
            fx->hold = (int)(0.300f * fx->rate);
        else if (fx->hold > 0)
            fx->hold--;
        if (fx->hold == 0) target = GATE_FLOOR;
    }
    if (target == 1.0f) store(&fx->gateOpened, true);
    fx->gateGain += (target > fx->gateGain ? fx->gateAttack : fx->gateRelease) * (target - fx->gateGain);
    x *= fx->gateGain;

    /* 留一份給嘯叫分析 */
    unsigned long long n = load(&fx->written);
    store(&fx->ring[n % FX_FFT], x);
    store(&fx->written, n + 1);
    return x;
}

void fx_clear_notches(Effects *fx) {
    for (int i = 0; i < FX_NOTCHES; i++) store(&fx->notchFreq[i], 0.0f);
    fx->candCount = 0;
    fx->nextSlot = 0;
}

static void fft(float *re, float *im) {
    for (int i = 1, j = 0; i < FX_FFT; i++) {
        int bit = FX_FFT >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j |= bit;
        if (i < j) {
            float t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }
    for (int len = 2; len <= FX_FFT; len <<= 1) {
        float a = -2 * PI_F / len;
        for (int k = 0; k < len / 2; k++) {
            float wr = cosf(a * k), wi = sinf(a * k);
            for (int i = k; i < FX_FFT; i += len) {
                int j = i + len / 2;
                float tr = re[j] * wr - im[j] * wi, ti = re[j] * wi + im[j] * wr;
                re[j] = re[i] - tr; im[j] = im[i] - ti;
                re[i] += tr; im[i] += ti;
            }
        }
    }
}

/* 某頻率附近（±2 格）的最大功率 */
static float near_power(const float *p, float bin) {
    int c = (int)(bin + 0.5f);
    float best = 0;
    for (int k = c - 2; k <= c + 2; k++)
        if (k > 0 && k < FX_FFT / 2 && p[k] > best) best = p[k];
    return best;
}

static void add_notch(Effects *fx, float freq) {
    /* 已經削過附近頻率就加深 */
    for (int i = 0; i < FX_NOTCHES; i++) {
        float f = load(&fx->notchFreq[i]);
        if (f > 0 && fabsf(f - freq) < f / NOTCH_Q) {
            store(&fx->notchDB[i], NOTCH_DEEP_DB);
            return;
        }
    }
    int slot = fx->nextSlot; /* 滿了就取代最舊的 */
    fx->nextSlot = (slot + 1) % FX_NOTCHES;
    store(&fx->notchDB[slot], NOTCH_FIRST_DB);
    store(&fx->notchFreq[slot], freq);
}

/* 嘯叫特徵：單一、突出、幾乎沒有泛音、頻率固定且沒有變小。 */
void fx_analyze(Effects *fx) {
    static _Thread_local float re[FX_FFT], im[FX_FFT], p[FX_FFT / 2];
    unsigned long long n = load(&fx->written);
    if (!load(&fx->howlOn) || n < FX_FFT || n == fx->analyzed) {
        fx->candCount = 0;
        return;
    }
    fx->analyzed = n;
    for (int i = 0; i < FX_FFT; i++) {
        float w = 0.5f - 0.5f * cosf(2 * PI_F * i / FX_FFT);
        re[i] = load(&fx->ring[(n + i) % FX_FFT]) * w;
        im[i] = 0;
    }
    fft(re, im);

    float binHz = fx->rate / FX_FFT, total = 0;
    int lo = (int)(150 / binHz), hi = (int)(12000 / binHz), peak = lo;
    if (hi > FX_FFT / 2 - 2) hi = FX_FFT / 2 - 2;
    for (int k = 1; k < FX_FFT / 2; k++) p[k] = re[k] * re[k] + im[k] * im[k];
    for (int k = lo; k <= hi; k++) {
        total += p[k];
        if (p[k] > p[peak]) peak = k;
    }
    float mean = total / (hi - lo + 1);

    /* Hann 窗下振幅 A 的正弦，峰值功率約 (A*N/4)^2 */
    float amplitude = sqrtf(p[peak]) * 4 / FX_FFT;
    bool howl = amplitude > 0.006f                     /* 約 -44 dBFS 以上 */
        && p[peak] > mean * 100                        /* 比平均高 20 dB */
        && peak > lo && peak < hi
        && p[peak] > 30 * p[peak - 6 > 0 ? peak - 6 : 1]
        && p[peak] > 30 * p[peak + 6 < FX_FFT / 2 ? peak + 6 : peak];

    float freq = 0;
    if (howl) {
        float a = logf(p[peak - 1] + 1e-20f), b = logf(p[peak] + 1e-20f), c = logf(p[peak + 1] + 1e-20f);
        float d = a - 2 * b + c;
        float bin = peak + (d != 0 ? 0.5f * (a - c) / d : 0);
        freq = bin * binHz;
        /* 人聲和樂器有泛音；嘯叫的 2、3、1/2 倍頻很弱（低 20 dB 以上） */
        howl = near_power(p, bin * 2) < p[peak] / 100
            && near_power(p, bin * 3) < p[peak] / 100
            && near_power(p, bin / 2) < p[peak] / 100;
    }
    if (!howl) {
        fx->candCount = 0;
        return;
    }
    if (fx->candCount && fabsf(freq - fx->candFreq) < binHz * 1.5f && p[peak] > fx->candPower / 4) {
        fx->candCount++;
    } else {
        fx->candCount = 1;
        fx->candPower = p[peak];
    }
    fx->candFreq = freq;
    if (fx->candCount >= HOWL_ROUNDS) {
        add_notch(fx, freq);
        fx->candCount = 0;
    }
}

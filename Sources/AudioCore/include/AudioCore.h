#ifndef AUDIOCORE_H
#define AUDIOCORE_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>

typedef struct PAEngine PAEngine;

/* 建立引擎。in/out 的聲道偏移是在聚集裝置裡的位置。 */
PAEngine *pa_create(UInt32 inOffset, UInt32 inCount, UInt32 outOffset, UInt32 outCount,
                    double sampleRate);
void pa_destroy(PAEngine *e);

/* 開始／停止指定裝置上的音訊回呼。 */
OSStatus pa_start(PAEngine *e, AudioObjectID device);
void pa_stop(PAEngine *e);

/* 可在任何執行緒呼叫。gain 與 ceiling 為線性振幅。 */
void pa_set_gain(PAEngine *e, float gain);
void pa_set_ceiling(PAEngine *e, float ceiling);
void pa_set_muted(PAEngine *e, bool muted);

/* 讀取上次讀取後的峰值（線性），讀完歸零。 */
float pa_take_input_peak(PAEngine *e);
float pa_take_output_peak(PAEngine *e);
bool pa_take_limited(PAEngine *e);
unsigned long long pa_callback_count(PAEngine *e);

/* 低頻切除、噪音閘門（threshold 為線性振幅）、自動嘯叫抑制 */
void pa_set_highpass(PAEngine *e, bool on);
void pa_set_gate(PAEngine *e, bool on, float threshold);
void pa_set_howl(PAEngine *e, bool on);
bool pa_take_gate_open(PAEngine *e);
/* 嘯叫分析：由非音訊執行緒定期呼叫（約每 50 ms） */
void pa_analyze(PAEngine *e);
int pa_notch_count(void);
float pa_notch_freq(PAEngine *e, int index); /* 0 = 未使用 */
void pa_clear_notches(PAEngine *e);

/* 實際的訊號處理，獨立出來方便測試。 */
void pa_process(PAEngine *e, const AudioBufferList *in, AudioBufferList *out);

#endif

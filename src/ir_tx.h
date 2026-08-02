#ifndef IR_TX_H_
#define IR_TX_H_

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

// IR LED接続ピンを初期化し、PWMキャリアを準備する（送信は無効状態で開始）
void ir_tx_init(uint32_t gpio_pin);

// キャリア周波数を変更する（デフォルト38kHz、10k〜100kHz程度を想定）
void ir_tx_set_frequency(uint32_t freq_hz);

// pattern_us: mark(発光), space(消灯) を交互に並べたマイクロ秒配列。先頭は必ずmark。
// count: pattern_usの要素数
// freq_hz: このパターンで使うキャリア周波数
// ブロッキング関数。呼び出し中はUSB処理が遅延する点に注意（v0.1の既知の制約）。
void ir_tx_send(const uint16_t *pattern_us, size_t count, uint32_t freq_hz);

// キャリアを直接ON/OFFする（タイミング制御なし）。ハードウェアの動作確認用。
void ir_tx_set_carrier(bool on);

#endif

#ifndef IR_RX_H_
#define IR_RX_H_

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#define IR_RX_BUF_LEN 512

// VS1838B OUTピンを初期化し、GPIO割り込みでのエッジ計測を準備する（開始はir_rx_start）
void ir_rx_init(uint32_t gpio_pin);

// キャプチャ開始。バッファをクリアし、次の立ち下がりエッジからmark/spaceの記録を始める。
// idle_timeout_usより長い無信号区間が続くと自動的に停止する（フレーム終端とみなす）。
void ir_rx_start(uint32_t idle_timeout_us);

// キャプチャ停止
void ir_rx_stop(void);

// キャプチャ中かどうか
bool ir_rx_is_capturing(void);

// メインループから定期的に呼ぶこと。idle_timeoutを超えたら自動停止する。
void ir_rx_poll_timeout(void);

// 記録されたmark/spaceの列を取得する。呼ぶとバッファはクリアされる。
// 戻り値: 実際に取得できた要素数（out_maxまで）
size_t ir_rx_read(uint16_t *out, size_t out_max);

// 直前にキャプチャが「タイムアウトで確定」した際、実際に計測された無信号時間(us)。
// 診断用。ir_rx_stop()による強制停止時は更新されない。
uint32_t ir_rx_last_idle_gap_us(void);

#endif

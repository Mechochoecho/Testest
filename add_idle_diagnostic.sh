#!/data/data/com.termux/files/usr/bin/bash
# 診断機能追加: キャプチャが確定した際の実測「無信号時間」を表示する
# これで「本当に25ms timeoutで切れたのか」「別の理由で切れたのか」が分かる
# 必ず Testest リポジトリのディレクトリの中で実行すること
set -e

mkdir -p "$(dirname "src/ir_rx.h")"
cat > "src/ir_rx.h" << 'PICOEOF_src_ir_rx_h_'
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
PICOEOF_src_ir_rx_h_

mkdir -p "$(dirname "src/ir_rx.c")"
cat > "src/ir_rx.c" << 'PICOEOF_src_ir_rx_c_'
#include "ir_rx.h"

#include "hardware/gpio.h"
#include "pico/time.h"
#include "pico/sync.h"

static uint32_t s_pin;

static volatile uint16_t s_buf[IR_RX_BUF_LEN];
static volatile size_t s_count = 0;
static volatile bool s_capturing = false;
static volatile bool s_first_edge_pending = true;
static volatile uint64_t s_last_edge_us = 0;
static volatile uint32_t s_idle_timeout_us = 20000;
static volatile uint32_t s_last_idle_gap_us = 0;

static critical_section_t s_cs;

static void ir_rx_gpio_callback(uint gpio, uint32_t events) {
    if (gpio != s_pin) return;
    if (!s_capturing) return;

    uint64_t now = time_us_64();

    critical_section_enter_blocking(&s_cs);

    if (s_first_edge_pending) {
        // VS1838Bはアクティブロー。最初の立ち下がりエッジ(信号開始)を基準にする。
        // それ以前のレベルは不定なので破棄する。
        if (events & GPIO_IRQ_EDGE_FALL) {
            s_first_edge_pending = false;
            s_last_edge_us = now;
        }
        critical_section_exit(&s_cs);
        return;
    }

    uint64_t delta = now - s_last_edge_us;
    s_last_edge_us = now;

    if (delta > 0xFFFF) delta = 0xFFFF;

    if (s_count < IR_RX_BUF_LEN) {
        s_buf[s_count++] = (uint16_t) delta;
    } else {
        // バッファ満杯。これ以上は捨てる（ホスト側が読みに来るまで待つ）。
        s_capturing = false;
    }

    critical_section_exit(&s_cs);
}

void ir_rx_init(uint32_t gpio_pin) {
    s_pin = gpio_pin;
    critical_section_init(&s_cs);

    gpio_init(gpio_pin);
    gpio_set_dir(gpio_pin, GPIO_IN);
    gpio_pull_up(gpio_pin); // VS1838Bはオープンコレクタ系のことが多いためプルアップ

    gpio_set_irq_enabled_with_callback(gpio_pin,
        GPIO_IRQ_EDGE_FALL | GPIO_IRQ_EDGE_RISE, true, &ir_rx_gpio_callback);
}

void ir_rx_start(uint32_t idle_timeout_us) {
    critical_section_enter_blocking(&s_cs);
    s_count = 0;
    s_first_edge_pending = true;
    s_idle_timeout_us = idle_timeout_us;
    s_last_edge_us = time_us_64();
    s_capturing = true;
    critical_section_exit(&s_cs);
}

void ir_rx_stop(void) {
    critical_section_enter_blocking(&s_cs);
    s_capturing = false;
    critical_section_exit(&s_cs);
}

bool ir_rx_is_capturing(void) {
    return s_capturing;
}

void ir_rx_poll_timeout(void) {
    if (!s_capturing) return;
    if (s_first_edge_pending) return; // まだ何も受信していないうちはタイムアウトさせない

    uint64_t now = time_us_64();
    critical_section_enter_blocking(&s_cs);
    uint64_t idle = now - s_last_edge_us;
    if (idle > s_idle_timeout_us && s_count > 0) {
        s_capturing = false;
        s_last_idle_gap_us = (idle > 0xFFFFFFFFu) ? 0xFFFFFFFFu : (uint32_t) idle;
    }
    critical_section_exit(&s_cs);
}

uint32_t ir_rx_last_idle_gap_us(void) {
    return s_last_idle_gap_us;
}

size_t ir_rx_read(uint16_t *out, size_t out_max) {
    critical_section_enter_blocking(&s_cs);
    size_t n = s_count < out_max ? s_count : out_max;
    for (size_t i = 0; i < n; i++) out[i] = s_buf[i];
    s_count = 0;
    critical_section_exit(&s_cs);
    return n;
}
PICOEOF_src_ir_rx_c_

mkdir -p "$(dirname "src/main_sniffer.c")"
cat > "src/main_sniffer.c" << 'PICOEOF_src_main_sniffer_c_'
// IR信号解析専用ファームウェア。android-ir-blaster/独自プロトコルとは無関係。
// USB CDC(シリアル)で受信データをそのままテキスト表示する。
// Android側は「Serial USB Terminal」等の汎用シリアルターミナルアプリで見られる
// （USB OTG経由、root不要）。
//
// リモコンのボタンを押すたびに、
//   - 生のmark/spaceパルス列(us)
//   - NECプロトコルらしき場合はアドレス/コマンドの解読結果
// を表示し続ける。何度でも押し直せる。ファームウェアの書き込み直しは不要。

#include <stdio.h>
#include "pico/stdlib.h"
#include "ir_rx.h"

#define GPIO_IR_RX 16
#define IDLE_TIMEOUT_US 25000

static bool nec_try_decode(const uint16_t *d, size_t n, uint32_t *addr, uint32_t *cmd) {
    // NECの基本形: リーダーmark(~9000us) + リーダーspace(~4500us) + 32bit(各bit: mark~560us + space)
    if (n < 2 + 64) return false;
    if (d[0] < 8000 || d[0] > 10500) return false;
    if (d[1] < 4000 || d[1] > 5000) return false; // リピートフレーム(space~2250us)は対象外

    uint32_t bits = 0;
    for (int i = 0; i < 32; i++) {
        uint16_t mark = d[2 + i * 2];
        uint16_t space = d[2 + i * 2 + 1];
        if (mark < 400 || mark > 800) return false;

        bool bit;
        if (space > 1300 && space < 2000) {
            bit = true;
        } else if (space > 350 && space < 800) {
            bit = false;
        } else {
            return false;
        }
        bits = (bits << 1) | (bit ? 1u : 0u);
    }

    *addr = (bits >> 16) & 0xFFFFu;
    *cmd = bits & 0xFFFFu;
    return true;
}

int main(void) {
    stdio_init_all();
    ir_rx_init(GPIO_IR_RX);

    // USBシリアルの接続確立を待つ（すぐ表示すると繋がる前に流れて見えないことがある）
    sleep_ms(3000);

    printf("\r\n=== Pico IR Sniffer ===\r\n");
    printf("リモコンのボタンを押してください。受信するたびに解析結果を表示します。\r\n\r\n");

    ir_rx_start(IDLE_TIMEOUT_US);

    while (true) {
        ir_rx_poll_timeout();

        if (!ir_rx_is_capturing()) {
            uint16_t buf[IR_RX_BUF_LEN];
            size_t n = ir_rx_read(buf, IR_RX_BUF_LEN);

            // printf(USB CDC経由)は遅い（数ms〜数十ms）。先に印字してしまうと
            // その間の信号を取りこぼして1本の信号が細切れに分断される原因になる。
            // 読み取ったデータは既にbufへコピー済みなので、先にキャプチャを再開してから
            // 印字する。
            ir_rx_start(IDLE_TIMEOUT_US);

            if (n > 0) {
                printf("---- 受信 %u エントリ (確定までの無信号時間: %lu us) ----\r\n",
                       (unsigned) n, (unsigned long) ir_rx_last_idle_gap_us());
                printf("RAW (us, mark始まり): ");
                for (size_t i = 0; i < n; i++) {
                    printf("%u%s", (unsigned) buf[i], (i + 1 < n) ? "," : "");
                }
                printf("\r\n");

                uint32_t addr = 0, cmd = 0;
                if (nec_try_decode(buf, n, &addr, &cmd)) {
                    printf("推定プロトコル: NEC\r\n");
                    printf("addr=0x%04lX cmd=0x%04lX (32bit生値=0x%08lX)\r\n",
                           (unsigned long) addr, (unsigned long) cmd,
                           (unsigned long) ((addr << 16) | cmd));
                } else {
                    printf("推定プロトコル: 不明（NECの標準形とは一致しませんでした。上記RAWを手がかりに確認してください）\r\n");
                }
                printf("\r\n");
            }
        }
    }

    return 0;
}
PICOEOF_src_main_sniffer_c_

git add -A
git commit -m "sniffer: add diagnostic output of measured idle gap at capture end"
git push
echo "診断機能 反映完了"

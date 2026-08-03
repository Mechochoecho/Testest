#!/data/data/com.termux/files/usr/bin/bash
# 根本原因の修正: タイマー読み取りのレースコンディションでキャプチャが誤って早期終了するバグ
# (now の取得をクリティカルセクション内に移動し、整数アンダーフローを防止)
# 必ず Testest リポジトリのディレクトリの中で実行すること
set -e

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

    critical_section_enter_blocking(&s_cs);
    // 注意: now の取得は必ずクリティカルセクションの内側で行うこと。
    // 外側で取得すると、その直後にISRがs_last_edge_usを更新した場合
    // 「未来の時刻」から「もっと未来の時刻」を引く形になり、符号なし整数の
    // 引き算がアンダーフローして異常に巨大な値(0xFFFFFFFF付近)になる。
    // これにより実際は信号が継続中でも誤ってタイムアウト扱いされてしまうバグがあった。
    uint64_t now = time_us_64();
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

git add -A
git commit -m "fix: race condition in ir_rx_poll_timeout caused unsigned underflow, ending captures prematurely"
git push
echo "根本原因の修正 反映完了"

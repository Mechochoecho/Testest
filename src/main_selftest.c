// ハードウェア単体テスト用ファームウェア。USB通信は一切行わない。
// 電源を入れるだけで動作する:
//
//   - IR LED(GP15) が 1秒ごとにON/OFFを繰り返す
//     → スマホのカメラ越しに見て、点滅しているか確認する（肉眼では見えない）
//   - VS1838B(GP16) が何かIR信号を受信するたびに、Pico基板上のLED(GP25)が
//     0.2秒だけ光る
//     → 手元のリモコンのボタンを押して、Pico基板上のLEDが反応するか確認する
//
// これでUSB/アプリ側の問題と、配線・ハードウェア側の問題を完全に切り分けられる。

#include "pico/stdlib.h"
#include "ir_tx.h"
#include "ir_rx.h"

#define GPIO_IR_TX 15
#define GPIO_IR_RX 16
#define LED_PIN    25 // Pico基板上のLED

int main(void) {
    stdio_init_all();

    ir_tx_init(GPIO_IR_TX);
    ir_rx_init(GPIO_IR_RX);

    gpio_init(LED_PIN);
    gpio_set_dir(LED_PIN, GPIO_OUT);
    gpio_put(LED_PIN, 0);

    ir_rx_start(20000); // 20ms無信号でキャプチャ完了とみなす

    bool tx_on = false;
    absolute_time_t next_tx_toggle = get_absolute_time();

    while (true) {
        // ---- 送信テスト: 1秒ごとにIR LEDのON/OFFを切り替える ----
        if (absolute_time_diff_us(get_absolute_time(), next_tx_toggle) <= 0) {
            tx_on = !tx_on;
            ir_tx_set_carrier(tx_on);
            next_tx_toggle = delayed_by_ms(get_absolute_time(), 1000);
        }

        // ---- 受信テスト: リモコンの信号を検知したら基板上LEDを光らせる ----
        ir_rx_poll_timeout();
        if (!ir_rx_is_capturing()) {
            uint16_t tmp[64];
            size_t n = ir_rx_read(tmp, 64);
            if (n > 0) {
                gpio_put(LED_PIN, 1);
                sleep_ms(200);
                gpio_put(LED_PIN, 0);
            }
            ir_rx_start(20000); // 次の受信に備える
        }
    }

    return 0;
}

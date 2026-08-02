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

            if (n > 0) {
                printf("---- 受信 %u エントリ ----\r\n", (unsigned) n);
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

            ir_rx_start(IDLE_TIMEOUT_US);
        }
    }

    return 0;
}

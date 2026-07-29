#include "pico/stdlib.h"
#include "tusb.h"

#include "ir_tx.h"
#include "ir_rx.h"
#include "proto.h"

#define GPIO_IR_TX 15
#define GPIO_IR_RX 16

int main(void) {
    stdio_init_all();

    tusb_init();
    ir_tx_init(GPIO_IR_TX);
    ir_rx_init(GPIO_IR_RX);

    while (true) {
        tud_task();       // TinyUSBのデバイス処理
        proto_task();     // 独自プロトコルのコマンド処理
        ir_rx_poll_timeout(); // 受信アイドルタイムアウトの監視
    }

    return 0;
}

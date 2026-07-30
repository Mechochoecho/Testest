#include "pico/stdlib.h"
#include "tusb.h"

#include "ir_tx.h"
#include "ir_rx.h"
#include "proto.h"
#include "proto_compat.h"
#include "usb_descriptors.h"

#define GPIO_IR_TX 15
#define GPIO_IR_RX 16

int main(void) {
    stdio_init_all();

    tusb_init();
    ir_tx_init(GPIO_IR_TX);
    ir_rx_init(GPIO_IR_RX);

    while (true) {
        tud_task();       // TinyUSBのデバイス処理

#if IR_DONGLE_COMPAT_MODE
        proto_compat_task(); // android-ir-blaster互換プロトコル
#else
        proto_task();         // 独自プロトコル（tools/ir_pico_test.py用）
#endif
        ir_rx_poll_timeout(); // 受信アイドルタイムアウトの監視
    }

    return 0;
}


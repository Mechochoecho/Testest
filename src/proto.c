#include "proto.h"
#include "ir_tx.h"
#include "ir_rx.h"

#include <string.h>
#include "tusb.h"

#define CMD_BUF_MAX 2048

static uint8_t cmd_buf[CMD_BUF_MAX];
static size_t cmd_len = 0;

// RX_POLL/RX_STOPの返送に使う作業バッファ（スタック節約のためstatic）
static uint16_t rx_tmp[IR_RX_BUF_LEN];

static void fill_from_usb(void) {
    while (tud_vendor_available() && cmd_len < CMD_BUF_MAX) {
        uint32_t n = tud_vendor_read(&cmd_buf[cmd_len], CMD_BUF_MAX - cmd_len);
        if (n == 0) break;
        cmd_len += n;
    }
}

void proto_task(void) {
    fill_from_usb();
    if (cmd_len == 0) return;

    uint8_t op = cmd_buf[0];
    size_t total_len;

    switch (op) {
        case CMD_PING:
        case CMD_RX_POLL:
        case CMD_RX_STOP:
        case CMD_GET_VERSION:
            total_len = 1;
            break;

        case CMD_RX_START:
            total_len = 1 + 4;
            break;

        case CMD_TX_RAW: {
            if (cmd_len < 7) return; // freq(4)+count(2)が揃うまで待つ
            uint16_t count;
            memcpy(&count, &cmd_buf[5], 2);
            total_len = 7 + (size_t) count * 2;
            if (total_len > CMD_BUF_MAX) {
                // 壊れた/巨大すぎる要求。再同期のため破棄。
                cmd_len = 0;
                return;
            }
            break;
        }

        default:
            // 未知のオペコード。1byte捨てて再同期を試みる。
            memmove(cmd_buf, cmd_buf + 1, --cmd_len);
            return;
    }

    if (cmd_len < total_len) return; // まだ全バイト届いていない

    switch (op) {
        case CMD_PING: {
            uint8_t ack = 0xAA;
            tud_vendor_write(&ack, 1);
            break;
        }

        case CMD_GET_VERSION: {
            uint8_t v[3] = {FW_VERSION_MAJOR, FW_VERSION_MINOR, FW_VERSION_PATCH};
            tud_vendor_write(v, sizeof(v));
            break;
        }

        case CMD_TX_RAW: {
            uint32_t freq;
            uint16_t count;
            memcpy(&freq, &cmd_buf[1], 4);
            memcpy(&count, &cmd_buf[5], 2);
            const uint16_t *pattern = (const uint16_t *) &cmd_buf[7];

            ir_tx_send(pattern, count, freq);

            uint8_t status = 0x00;
            tud_vendor_write(&status, 1);
            break;
        }

        case CMD_RX_START: {
            uint32_t timeout;
            memcpy(&timeout, &cmd_buf[1], 4);
            ir_rx_start(timeout);

            uint8_t status = 0x00;
            tud_vendor_write(&status, 1);
            break;
        }

        case CMD_RX_POLL: {
            ir_rx_poll_timeout();
            uint8_t done = ir_rx_is_capturing() ? 0 : 1;
            tud_vendor_write(&done, 1);

            if (done) {
                size_t n = ir_rx_read(rx_tmp, IR_RX_BUF_LEN);
                uint16_t count16 = (uint16_t) n;
                tud_vendor_write(&count16, 2);
                if (n > 0) tud_vendor_write(rx_tmp, n * 2);
            }
            break;
        }

        case CMD_RX_STOP: {
            ir_rx_stop();
            size_t n = ir_rx_read(rx_tmp, IR_RX_BUF_LEN);
            uint16_t count16 = (uint16_t) n;
            tud_vendor_write(&count16, 2);
            if (n > 0) tud_vendor_write(rx_tmp, n * 2);
            break;
        }

        default:
            break;
    }

    tud_vendor_write_flush();

    cmd_len -= total_len;
    if (cmd_len > 0) memmove(cmd_buf, cmd_buf + total_len, cmd_len);
}

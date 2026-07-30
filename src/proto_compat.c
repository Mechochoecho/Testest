// android-ir-blaster (org.nslabs.ir_blaster.UsbProtocolFormatter) 互換のTX受信処理。
//
// ワイヤーフォーマット（実ソースから確認済み）:
//
//   物理フレーム: 0x02, len, eVal, b1, b2, <len-3 バイトのdata>
//
//   ハンドシェイクフレーム（len==9固定）:
//     eVal, 0x01, 0x01, 'S','T', fVal, 'S','E','N'
//     → デバイス側は無視するだけでよい（応答不要）
//
//   TX_RAWフレーム（1個以上のフラグメントに分割される。b1=total, b2=index(1始まり)）:
//     フラグメントのdataを index=1..total の順に連結すると、以下のpayloadになる:
//       'S','T', fVal, 'D', 0x00, <RLE本体>, 'E','N'
//     RLE本体は1バイト = { bit7: 1=mark(発光)/0=space(消灯), bit6-0: 16us単位の長さ(1-127) }
//     127単位(2032us)を超える長さは、同じ極性のバイトを複数連続させて表現する。
//     周波数の情報はワイヤー上に含まれない → 38kHz固定として送信する。
//
//   1フレームの最大サイズは56バイトのdata + 5バイトヘッダ = 61バイト（README記載の56byte分割と一致）。

#include "proto_compat.h"
#include "ir_tx.h"

#include <string.h>
#include <stdbool.h>
#include "tusb.h"

#define FRAME_BUF_MAX    512   // 物理フレーム1個分の受信バッファ（実際は最大61byte程度）
#define PAYLOAD_BUF_MAX  4096  // 複数フラグメントを連結するための再構成バッファ
#define DURATIONS_MAX    1024  // デコード後のmark/space配列の最大要素数

static uint8_t frame_buf[FRAME_BUF_MAX];
static size_t frame_len = 0;

static uint8_t payload_buf[PAYLOAD_BUF_MAX];
static size_t payload_len = 0;

static bool seq_active = false;
static uint8_t seq_eval = 0;
static uint8_t seq_total = 0;
static uint8_t seq_next_index = 0;

static uint16_t durations[DURATIONS_MAX];

static void fill_from_usb(void) {
    while (tud_vendor_available() && frame_len < FRAME_BUF_MAX) {
        uint32_t n = tud_vendor_read(&frame_buf[frame_len], FRAME_BUF_MAX - frame_len);
        if (n == 0) break;
        frame_len += n;
    }
}

static void resync_drop_one(void) {
    if (frame_len > 0) {
        memmove(frame_buf, frame_buf + 1, --frame_len);
    }
}

// RLE本体をmark/space(us)の配列にデコードして送信する。
static void decode_and_transmit(const uint8_t *payload, size_t len) {
    // 最低でも 'S','T',fVal,'D',0x00,'E','N' の7byteは必要（RLE本体が空でも）
    if (len < 7) return;
    if (!(payload[0] == 0x53 && payload[1] == 0x54 &&
          payload[3] == 0x44 && payload[4] == 0x00)) {
        return; // 期待するヘッダと一致しない。壊れたデータとして破棄。
    }
    if (!(payload[len - 2] == 0x45 && payload[len - 1] == 0x4E)) {
        return; // トレーラ不一致。破棄。
    }

    const uint8_t *rle = &payload[5];
    size_t rle_len = len - 7;

    size_t count = 0;
    bool have_run = false;
    bool run_is_mark = false;
    uint32_t run_us = 0;

    for (size_t i = 0; i < rle_len && count < DURATIONS_MAX; i++) {
        uint8_t b = rle[i];
        bool is_mark = (b & 0x80) != 0;
        uint32_t units = b & 0x7F;
        uint32_t us = units * 16;

        if (have_run && is_mark == run_is_mark) {
            // 同じ極性が連続 = 元は1つの長い区間が分割されたもの。合算する。
            run_us += us;
        } else {
            if (have_run) {
                durations[count++] = (run_us > 0xFFFF) ? 0xFFFF : (uint16_t) run_us;
            }
            run_is_mark = is_mark;
            run_us = us;
            have_run = true;
        }
    }
    if (have_run && count < DURATIONS_MAX) {
        durations[count++] = (run_us > 0xFFFF) ? 0xFFFF : (uint16_t) run_us;
    }

    if (count > 0) {
        // ワイヤー上に周波数情報が無いため38kHz固定
        ir_tx_send(durations, count, 38000);
    }
}

static void handle_frame_body(const uint8_t *body, size_t len) {
    // ハンドシェイク判定: eVal,0x01,0x01,'S','T',fVal,'S','E','N' (9byte固定)
    if (len == 9 && body[1] == 0x01 && body[2] == 0x01 &&
        body[3] == 0x53 && body[4] == 0x54 &&
        body[6] == 0x53 && body[7] == 0x45 && body[8] == 0x4E) {
        return; // 応答不要
    }

    if (len < 3) return; // eVal+total+indexすら無い

    uint8_t eVal = body[0];
    uint8_t total = body[1];
    uint8_t index = body[2];
    const uint8_t *data = &body[3];
    size_t data_len = len - 3;

    if (total == 0 || index == 0 || index > total) return; // 異常値

    if (index == 1) {
        seq_eval = eVal;
        seq_total = total;
        seq_next_index = 1;
        payload_len = 0;
        seq_active = true;
    } else if (!seq_active) {
        return; // 先頭フラグメントを取りこぼした。次のシーケンス開始を待つ。
    }

    if (eVal != seq_eval || total != seq_total || index != seq_next_index) {
        // 順序不整合・別シーケンス混入。破棄して再同期。
        seq_active = false;
        payload_len = 0;
        return;
    }

    if (payload_len + data_len <= PAYLOAD_BUF_MAX) {
        memcpy(&payload_buf[payload_len], data, data_len);
        payload_len += data_len;
    }
    seq_next_index++;

    if (index == total) {
        decode_and_transmit(payload_buf, payload_len);
        seq_active = false;
        payload_len = 0;
    }
}

void proto_compat_task(void) {
    fill_from_usb();

    while (frame_len >= 2) {
        if (frame_buf[0] != 0x02) {
            resync_drop_one();
            continue;
        }

        size_t body_len = frame_buf[1];
        size_t total_frame = 2 + body_len;

        if (frame_len < total_frame) break; // まだ全バイト届いていない

        handle_frame_body(&frame_buf[2], body_len);

        memmove(frame_buf, frame_buf + total_frame, frame_len - total_frame);
        frame_len -= total_frame;
    }
}

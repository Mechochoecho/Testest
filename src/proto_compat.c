// android-ir-blaster (org.nslabs.ir_blaster) 互換のUSB通信処理。
// 送信(UsbProtocolFormatter)側と、Learning Mode(TiqiaaUsbLearner)側の両方を実装する。
//
// ===== 共通の物理フレーム構造（ホスト→デバイス、マーカー0x02） =====
//   0x02, len, eVal, b1, b2, <len-3 バイトのdata>
//   dataを index=1..total(=b1) の順に連結すると1つのpayloadになる（56byte単位分割）
//
// ===== ハンドシェイクフレーム（UsbProtocolFormatter起動時、len==9固定） =====
//   eVal, 0x01, 0x01, 'S','T', fVal, 'S','E','N'
//   → デバイス側は無視するだけでよい（応答不要）
//   ※ 注意: 再構成後のpayloadが ['S','T',fVal,'S','E','N'] という6byteになり、
//     これは後述の「モードコマンド」の cmd='S' と構造上区別できないケースがある。
//     実害は無い（誤ってACKを返しても、ホスト側は起動時のdrain処理で単に読み捨てるだけ）
//     ため、そのまま許容している。将来的に本当に問題が出たら再検討する。
//
// ===== TX_RAWペイロード（UsbProtocolFormatter、送信専用） =====
//   'S','T', fVal, 'D', 0x00, <RLE本体>, 'E','N'
//   RLE本体: 1byte = {bit7: 1=mark/0=space, bit6-0: 16us単位の長さ(1-127)}
//   127単位(2032us)超は同極性のバイトを複数連続させて表現。周波数情報は無い→38kHz固定。
//
// ===== モードコマンド（TiqiaaUsbLearner、Learning Mode用） =====
//   ホスト→デバイス payload: 'S','T', seq, cmd, 'E','N' (6byte)
//     cmd: 'L'=idle(0) 'S'=send-ready(1) 'R'=learn開始(2) 'H'=?(3) 'O'=?(4) 'C'=cancel(6) 'V'=version?(7)
//   デバイス→ホスト ACK payload: 'S','T', seq, cmd, meta, 'E','N' (7byte)
//     meta の bit3-4 が状態値 (state << 3)
//     ※ デバイス→ホストのフレームはマーカーが 0x01 になる（ホスト→デバイスの0x02と違う）
//
// ===== 学習結果フレーム（デバイス→ホスト、cmd='D'） =====
//   'S','T', seq, 'D', meta, <RLE本体>, 'E','N'  （TX_RAWと同じRLE形式）
//   マーカー0x01で56byte単位に分割して送信する。

#include "proto_compat.h"
#include "ir_tx.h"
#include "ir_rx.h"

#include <string.h>
#include <stdbool.h>
#include "tusb.h"

#define FRAME_BUF_MAX     512   // 物理フレーム1個分の受信バッファ
#define PAYLOAD_BUF_MAX   4096  // 複数フラグメントを連結するための再構成バッファ
#define DURATIONS_MAX     1024  // デコード後のmark/space配列の最大要素数
#define LEARN_RLE_MAX      512  // 学習結果RLEエンコードの最大バイト数
#define LEARN_IDLE_TIMEOUT_US 25000 // 学習時、この無信号区間が続いたら1フレーム受信完了とみなす

// ---- ホストからの受信バッファ＆フラグメント再構成 ----

static uint8_t frame_buf[FRAME_BUF_MAX];
static size_t frame_len = 0;

static uint8_t payload_buf[PAYLOAD_BUF_MAX];
static size_t payload_len = 0;

static bool seq_active = false;
static uint8_t seq_eval = 0;
static uint8_t seq_total = 0;
static uint8_t seq_next_index = 0;

static uint16_t durations[DURATIONS_MAX];

// ---- デバイス→ホスト送信用のカウンタ ----

static uint8_t ack_seq_counter = 0;
static uint8_t env_seq_counter = 0;

// ---- Learning Modeの状態 ----

static uint8_t current_state = 0; // 0=idle 1=send-ready 2=learn ...
static bool learn_pending = false;

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

static uint8_t next_seq(void) {
    ack_seq_counter++;
    if (ack_seq_counter == 0) ack_seq_counter = 1;
    return ack_seq_counter;
}

static uint8_t next_env(void) {
    env_seq_counter = (env_seq_counter < 0x0F) ? (uint8_t)(env_seq_counter + 1) : 1;
    return env_seq_counter;
}

// payloadをマーカーmarker、56byte単位のフレームに分割してBulk INへ書き込む。
static void send_wrapped(uint8_t marker, const uint8_t *payload, size_t len) {
    const size_t max_chunk = 0x38;
    size_t total = (len + max_chunk - 1) / max_chunk;
    if (total == 0) total = 1;
    if (total > 255) return; // 想定外に大きい。安全のため送らない。

    uint8_t env = next_env();
    size_t offset = 0;

    for (size_t idx = 1; idx <= total; idx++) {
        size_t remain = len - offset;
        size_t take = remain < max_chunk ? remain : max_chunk;

        uint8_t frame[5 + 0x38];
        frame[0] = marker;
        frame[1] = (uint8_t) (take + 3);
        frame[2] = env;
        frame[3] = (uint8_t) total;
        frame[4] = (uint8_t) idx;
        if (take > 0) memcpy(&frame[5], &payload[offset], take);

        tud_vendor_write(frame, 5 + take);
        tud_vendor_write_flush();

        offset += take;
    }
}

// モードコマンドへのACKを返す（マーカー0x01）
static void send_ack(uint8_t cmd, uint8_t state) {
    uint8_t payload[7];
    payload[0] = 0x53; // 'S'
    payload[1] = 0x54; // 'T'
    payload[2] = next_seq();
    payload[3] = cmd;
    payload[4] = (uint8_t) ((state & 0x03) << 3);
    payload[5] = 0x45; // 'E'
    payload[6] = 0x4E; // 'N'
    send_wrapped(0x01, payload, sizeof(payload));
}

// mark/space(us)配列をRLEエンコードする（UsbProtocolFormatter.encodeBodyIntoと同じ方式）
static size_t rle_encode(const uint16_t *durs, size_t count, uint8_t *out, size_t out_max) {
    size_t n = 0;
    for (size_t i = 0; i < count && n < out_max; i++) {
        uint32_t units = durs[i] / 16;
        if (units == 0) units = 1;
        bool is_mark = (i % 2 == 0);
        while (units > 0 && n < out_max) {
            uint32_t chunk = units > 0x7F ? 0x7F : units;
            units -= chunk;
            uint8_t b = (uint8_t) chunk;
            if (is_mark) b |= 0x80;
            out[n++] = b;
        }
    }
    return n;
}

// 学習完了した生データを 'D' フレームとしてホストへ送る（マーカー0x01）
static void send_learn_result(const uint16_t *durs, size_t count) {
    uint8_t buf[5 + LEARN_RLE_MAX + 2];

    size_t rle_len = rle_encode(durs, count, &buf[5], LEARN_RLE_MAX);

    buf[0] = 0x53; // 'S'
    buf[1] = 0x54; // 'T'
    buf[2] = next_seq();
    buf[3] = 0x44; // 'D'
    buf[4] = 0x00; // meta
    buf[5 + rle_len] = 0x45;     // 'E'
    buf[5 + rle_len + 1] = 0x4E; // 'N'

    send_wrapped(0x01, buf, 5 + rle_len + 2);
}

// TX_RAWのRLE本体をデコードしてIR送信する
static void decode_and_transmit(const uint8_t *rle, size_t rle_len) {
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
            run_us += us; // 同じ極性が連続 = 元は1つの長い区間が分割されたもの
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
        ir_tx_send(durations, count, 38000); // ワイヤー上に周波数情報が無いため38kHz固定
    }
}

// モードコマンド('L'/'S'/'R'/'H'/'O'/'C'/'V')を処理する
static void handle_mode_command(uint8_t cmd) {
    switch (cmd) {
        case 'L': // idle
            ir_rx_stop();
            learn_pending = false;
            current_state = 0;
            send_ack('L', current_state);
            break;

        case 'S': // send-ready（学習済み信号の再生前に送られる）
            ir_rx_stop();
            learn_pending = false;
            current_state = 1;
            send_ack('S', current_state);
            break;

        case 'R': // 学習開始
            current_state = 2;
            learn_pending = true;
            ir_rx_start(LEARN_IDLE_TIMEOUT_US);
            send_ack('R', current_state);
            break;

        case 'H': // 用途未確認。ひとまずACKのみ返す。
            current_state = 3;
            send_ack('H', current_state);
            break;

        case 'O': // 用途未確認。ひとまずACKのみ返す。
            current_state = 4;
            send_ack('O', current_state);
            break;

        case 'C': // キャンセル
            ir_rx_stop();
            learn_pending = false;
            current_state = 0;
            send_ack('C', current_state);
            break;

        case 'V': // 用途未確認（バージョン照会?）。現在の状態を返す。
            send_ack('V', current_state);
            break;

        default:
            break;
    }
}

// 再構成済みのpayloadを解釈して分岐する
static void handle_reassembled_payload(const uint8_t *payload, size_t len) {
    // モードコマンド判定: 'S','T',seq,cmd,'E','N' (6byte固定)
    if (len == 6 && payload[0] == 0x53 && payload[1] == 0x54 &&
        payload[4] == 0x45 && payload[5] == 0x4E) {
        handle_mode_command(payload[3]);
        return;
    }

    // TX_RAW判定: 'S','T',seq,'D',0x00,<RLE>,'E','N' (7byte以上)
    if (len >= 7 && payload[0] == 0x53 && payload[1] == 0x54 &&
        payload[3] == 0x44 && payload[4] == 0x00 &&
        payload[len - 2] == 0x45 && payload[len - 1] == 0x4E) {
        decode_and_transmit(&payload[5], len - 7);
        return;
    }

    // それ以外は未知のペイロード。無視する。
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
        seq_active = false; // 順序不整合・別シーケンス混入。破棄して再同期。
        payload_len = 0;
        return;
    }

    if (payload_len + data_len <= PAYLOAD_BUF_MAX) {
        memcpy(&payload_buf[payload_len], data, data_len);
        payload_len += data_len;
    }
    seq_next_index++;

    if (index == total) {
        handle_reassembled_payload(payload_buf, payload_len);
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

    // 学習中に受信が完了したら結果を送る
    if (learn_pending && !ir_rx_is_capturing()) {
        static uint16_t rx_tmp[IR_RX_BUF_LEN];
        size_t n = ir_rx_read(rx_tmp, IR_RX_BUF_LEN);
        learn_pending = false;
        if (n > 0) {
            send_learn_result(rx_tmp, n);
        }
    }
}

#!/data/data/com.termux/files/usr/bin/bash
# v0.4 android-ir-blaster Learning Mode(受信)対応 パッチスクリプト
# 必ず Testest リポジトリのディレクトリの中で実行すること
set -e

mkdir -p "$(dirname "src/proto_compat.c")"
cat > "src/proto_compat.c" << 'PICOEOF_src_proto_compat_c_'
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
PICOEOF_src_proto_compat_c_

mkdir -p "$(dirname "docs/PROTOCOL.md")"
cat > "docs/PROTOCOL.md" << 'PICOEOF_docs_PROTOCOL_md_'
# v0.1 プロトコル仕様（独自、android-ir-blaster非互換）

USB Vendorクラス、Bulk OUT (EP1 OUT) / Bulk IN (EP1 IN)。マルチバイト値はすべてリトルエンディアン。
VID/PIDは `src/usb_descriptors.h` を参照（デフォルト `0x2E8A:0xF00D`、暫定値）。

## コマンド一覧（Host → Device, Bulk OUT）

| opcode | 名前 | ペイロード | 説明 |
|---|---|---|---|
| 0x01 | PING | なし | 疎通確認 |
| 0x02 | TX_RAW | freq_hz(u32) + count(u16) + count個のduration_us(u16) | IR送信。durationはmark(発光)始まりでmark/space交互 |
| 0x03 | RX_START | idle_timeout_us(u32) | 受信キャプチャ開始 |
| 0x04 | RX_POLL | なし | キャプチャ状態確認（完了していればデータも一緒に返る） |
| 0x05 | RX_STOP | なし | キャプチャ強制終了して結果を取得 |
| 0x06 | GET_VERSION | なし | ファームウェアバージョン取得 |

## レスポンス（Device → Host, Bulk IN）

| opcode | レスポンス |
|---|---|
| PING | `0xAA` の1byte |
| GET_VERSION | major(u8), minor(u8), patch(u8) の3byte |
| TX_RAW | status(u8)。0x00=成功 |
| RX_START | status(u8)。0x00=成功 |
| RX_POLL | done(u8: 0=継続中/1=完了)。done=1のときのみ続けて count(u16) + count個のduration_us(u16) |
| RX_STOP | count(u16) + count個のduration_us(u16)（未完了でもその時点までのデータを返す） |

## 送受信データの意味

- `duration_us` は常に先頭が **mark（発光/信号あり）**、次が **space（消灯/信号なし）**、以降交互。
- VS1838Bはアクティブロー出力のため、受信側ドライバ内部で極性を吸収し、送信側と同じ「mark始まり」の形式に揃えて返す。
- 1エントリの最大値は65535us（それを超える場合はクランプされる。長いギャップの扱いは今後見直す可能性あり）。

## 既知の制約（v0.1時点）

- `ir_tx_send()` はブロッキング実装。送信中はUSB処理が遅延する（他のBulk転送が詰まる可能性あり）。
- タイミング精度はソフトウェアループ依存。USB割り込み等によるジッタは未対策（v0.2以降でPIOオフロードを検討）。
- RX_POLLで完了通知を受け取る前にホストが次のコマンドを送ると未定義動作になる可能性あり（現状は単純なコマンド/レスポンスの逐次処理のみ想定）。

---

# android-ir-blaster 実プロトコル互換（v0.3、実装済み・TX側確定）

`UsbProtocolFormatter`（Kotlin, `org.nslabs.ir_blaster`）のソースコードから確認済み。
実装は `src/proto_compat.c`、有効化はデフォルト（`IR_DONGLE_COMPAT_MODE=ON`）。

## USBフィルタ

VID `0x10C4`, PID `0x8468`（README記載の2候補のうち、こちらを採用。`src/usb_descriptors.h`で切替可能）

## 物理フレーム形式

```
0x02, len, eVal, b1, b2, <len-3 バイトのdata>
```

- `len` はこのバイトの直後に続くバイト数（`eVal, b1, b2, data` の合計）
- `eVal` は1〜15を巡回するカウンタ、`fVal` は1〜127を巡回するカウンタ（アプリ側がインクリメントする。デバイス側は単に届いた値をそのまま扱うだけで良い）
- 1フレームは最大 `5 + 56 = 61` バイト（56byte分割はREADMEの記載と一致）

## ハンドシェイクフレーム（len==9固定）

```
eVal, 0x01, 0x01, 'S','T', fVal, 'S','E','N'
```

デバイス側は何も応答しなくてよい。アプリは短いタイムアウト（10〜20ms）でbulk INを覗くだけで、無ければ諦めて先に進む実装になっている。

## TX_RAWフレーム（1個以上のフラグメント、b1=total, b2=index、index=1始まり）

各フラグメントのdataを index=1..total の順に連結すると、以下のpayloadが得られる：

```
'S','T', fVal, 'D', 0x00, <RLE本体...>, 'E','N'
```

### RLE本体のフォーマット

1バイト = 1区間。
- bit7: `1`=mark（発光）, `0`=space（消灯）
- bit6-0: 長さ（16us単位、1〜127＝最大2032us）

127単位（2032us）を超える長さは、**同じ極性のバイトを複数連続**させて表現する（デコード時は同極性が続く限り合算する）。

### 送信パターンの末尾調整（正規化）

送信元がパターンを組み立てる際、パターン長が偶数（＝最後がspace）の場合、最後のspace長を次のように置き換えている：

```
tail = (last_gap_us > 3000) ? (last_gap_us - 3000) : 10
```

これは送信側の処理なので、デバイス側では特に対応不要（届いたRLEをそのままデコードして送信すればよい）。

### 周波数について

**ワイヤー上に周波数情報は一切含まれない。** つまりこのプロトコルに対応するドングルは固定周波数（38kHz）での送信を前提にしている。`src/proto_compat.c` でも38kHz固定として`ir_tx_send()`を呼んでいる。

## 未確認（Learning Mode / RX、v0.4で着手予定）

`UsbIrTransmitter`（実際にbulk転送を行うクラス）と`UsbDiscoveryManager`（デバイス検出・インターフェース取得）、および受信側のフォーマットはまだソースを確認していない。Learning Modeを実装する際は、これらのソースも同様に確認が必要。

---

# Learning Mode（受信）互換 — v0.4、実装済み

`TiqiaaUsbLearner.kt`（`UsbLearnerSession`実装）のソースから確認済み。実装は`src/proto_compat.c`内、TX処理と統合されている。

## 重要な違い：デバイス→ホストのマーカーは 0x01

TX側（ホスト→デバイス）のフレームマーカーは `0x02` だったが、Learning Mode関連でデバイス→ホストに送るフレームのマーカーは **`0x01`**。フレームの残りの構造（`len, env, total, index, data`）は同じ。

## モードコマンド（ホスト→デバイス、payload 6byte固定）

```
'S','T', seq, cmd, 'E','N'
```

| cmd | 意味 | 状態値 |
|---|---|---|
| `'L'` (0x4C) | idle（待機） | 0 |
| `'S'` (0x53) | send-ready（学習済み信号の再生前） | 1 |
| `'R'` (0x52) | 学習開始 | 2 |
| `'H'` (0x48) | 用途未確認 | 3 |
| `'O'` (0x4F) | 用途未確認 | 4 |
| `'C'` (0x43) | キャンセル | 6（内部値。状態としては0扱い） |
| `'V'` (0x56) | 用途未確認（バージョン照会?） | - |

`'B'`(8)というtypeも`parseFrame`のswitchに存在するが、対応するモードコマンドの送信元はソース上まだ確認できていない。

## ACKフレーム（デバイス→ホスト、payload 7byte、マーカー0x01）

```
'S','T', seq, cmd（受け取ったコマンドをそのまま返す）, meta, 'E','N'
meta の bit3-4 に状態値を入れる: meta = (state & 0x3) << 3
```

ホスト側は「acknowledgeフレームが何か1つでも届いたか」だけを見ていて、`currentState`の更新にmetaのbit3-4をそのまま使う。cmdの中身が要求と一致しているかまでは厳密にチェックしていない（＝多少ラフでも動く）。

## 学習フロー

1. ホストが `'R'` を送る → デバイスは `state=2` でACK
2. デバイスはVS1838Bでの受信を開始する（既存の`ir_rx_start()`を流用、無信号区間25msでフレーム完了とみなす）
3. 受信完了したら、TX_RAWと同じRLE形式で `'D'` フレームを組み立てて送信:
   ```
   'S','T', seq, 'D', meta, <RLE本体>, 'E','N'
   ```
   マーカー0x01・56byte単位分割で送る
4. ホストは`type==5(cmd='D')`のフレームを受け取るまで待ち続ける（デフォルト最大30秒）
5. タイムアウトした場合、ホストは `'C'`→`'L'` の順にモードコマンドを送って終了する

## 再生（学習した信号をそのまま送り直す）

`replayOpaqueFrame()`は、まず `'S'` (send-ready) を送ってACKを待ち、その後、学習時に受け取った `'D'` フレームの中身（seqバイトだけ差し替え）をそのままTX_RAWと同じ経路で送り返す。つまり学習結果として保存された`opaqueFrameBase64`は、そのまま再送信できるデータになっている。

## 既知の未解決事項

- `UsbProtocolFormatter`のハンドシェイクフレームと、モードコマンド`cmd='S'`は再構成後のバイト列が構造的に区別できない（詳細は`src/proto_compat.c`冒頭のコメント参照）。実害はほぼ無いと判断しそのまま実装している。
- `'H'`, `'O'`, `'V'`, `'B'`コマンドの正確な意味・使用タイミングは未確認。現状はACKを返すのみで実際の副作用は実装していない。
- 学習した信号の保存・一覧・削除といったアプリ内のデータ管理部分は今回のスコープ外（デバイス側の実装には影響しない）。


PICOEOF_docs_PROTOCOL_md_

mkdir -p "$(dirname "README.md")"
cat > "README.md" << 'PICOEOF_README_md_'
# Pico IR Dongle (working title)

Raspberry Pi Pico を Android / Windows / Linux 対応の USB 赤外線ドングルにするプロジェクト。
最優先ターゲットは [android-ir-blaster](https://github.com/iodn/android-ir-blaster) との互換。

## 現在地（v0.4）

android-ir-blaster互換のTX側・Learning Mode（受信）側の両方が実装済みです。`docs/PROTOCOL.md`にプロトコル全容を記載しています。

- ✅ USB Vendor/Bulkデバイスとして列挙（互換モード時はandroid-ir-blaster対応VID/PID）
- ✅ android-ir-blasterからのTXコマンドを受信し、38kHzでIR LEDから送信
- ✅ android-ir-blasterのLearning ModeからPicoの受信機能を呼び出し、学習→アプリでの保存が可能
- ✅ 独自プロトコルモード（`IR_DONGLE_COMPAT_MODE=OFF`でビルド）も引き続き利用可能
- ✅ GitHub Actionsで push するたびに両モードの`.uf2`を自動ビルド

## ロードマップ

| バージョン | 内容 |
|---|---|
| v0.1 | USB列挙 / 独自プロトコルでRaw送信 / CI自動ビルド |
| v0.2 | VS1838B受信の安定化、ノイズ除去、複数プロトコルのデコード（NEC等） |
| v0.3 | android-ir-blaster実プロトコル互換（TX側） |
| v0.4 | android-ir-blaster Learning Mode互換（RX側） ← **今ここ** |
| v1.0 | ドキュメント整備、Windows/Linux単体ツールの配布、実機での動作検証・チューニング |

## 残っている不確実性

このファームウェアは実機での動作確認がまだ済んでいません（開発環境がネットワーク遮断されておりARMクロスビルド・実機テストができないため）。プロトコル自体はKotlinソースから正確に読み取っていますが、以下は未検証です：

- タイミング精度（ソフトウェアループのジッタがLearning Mode側のACK応答速度やIR送受信精度にどう影響するか）
- `'H'`, `'O'`, `'V'`コマンドの正確な意味（現状ACKのみ返す実装）
- ハンドシェイクフレームとモードコマンド`'S'`の構造的な曖昧さ（`docs/PROTOCOL.md`参照、実害は無いと想定）

実機で試して問題が出たら、そのログや症状を教えてください。
## ビルド方法（ローカルでやる場合）

```bash
git clone --recurse-submodules https://github.com/raspberrypi/pico-sdk.git
export PICO_SDK_PATH=$(pwd)/pico-sdk
mkdir build && cd build
cmake ..
make -j4
```

生成された `build/pico_ir_dongle.uf2` を、BOOTSELボタンを押しながらPicoをUSB接続 → 出てくるドライブにドラッグ&ドロップで書き込み。

## ビルド方法（GitHub Actions、CMakeを自分でやりたくない場合）

push するだけで `.github/workflows/build.yml` が自動ビルドします。
Actions タブ → 該当のワークフロー実行 → Artifacts の `firmware` の中に2つ入っています：

- `firmware-compat.uf2` — android-ir-blaster互換モード（**通常はこちらを使う**）
- `firmware-custom.uf2` — 独自プロトコルモード（`tools/ir_pico_test.py`での単体動作確認用）

## ハードウェア接続

| 信号 | Pico GPIO | 部品 |
|---|---|---|
| IR送信 | GP15 | IR LED（トランジスタ経由推奨、電流制限） |
| IR受信 | GP16 | VS1838B OUT |
| （予備）| GP17 | D331使用時の制御ピン用に確保 |

VS1838Bの出力はアクティブLow（信号受信中はLow）。3.3V/GND/OUTの3ピン。Picoは3.3V系なので直結可。
IR LEDは順方向電流が大きいので、GPIOに直結せずNPNトランジスタ（2SC1815等）でドライブすること。

## ディレクトリ構成

```
src/            firmware本体（Pico SDK + TinyUSB）
tools/          ホスト側テストツール（Python）
docs/           プロトコル仕様メモ
.github/workflows/  CI設定
```
PICOEOF_README_md_

git add -A
git commit -m "v0.4: android-ir-blaster Learning Mode (RX) compat implemented"
git push
echo "v0.4 反映完了"

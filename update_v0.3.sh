#!/data/data/com.termux/files/usr/bin/bash
# v0.3 android-ir-blaster互換モード 追加パッチスクリプト
# 必ず Testest リポジトリのディレクトリの中で実行すること (cd してから bash update_v0.3.sh)
set -e

mkdir -p "$(dirname "src/proto_compat.h")"
cat > "src/proto_compat.h" << 'PICOEOF_src_proto_compat_h_'
#ifndef PROTO_COMPAT_H_
#define PROTO_COMPAT_H_

// android-ir-blaster (UsbProtocolFormatter) 互換のTX受信処理。
// メインループから毎回呼ぶこと。応答は一切返さない
// （アプリ側は短いタイムアウトでbulk INを覗きに来るだけで、
//  無ければ諦めて先に進む実装のため、デバイス側からの返答は不要）。
void proto_compat_task(void);

#endif
PICOEOF_src_proto_compat_h_

mkdir -p "$(dirname "src/proto_compat.c")"
cat > "src/proto_compat.c" << 'PICOEOF_src_proto_compat_c_'
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
PICOEOF_src_proto_compat_c_

mkdir -p "$(dirname "src/usb_descriptors.h")"
cat > "src/usb_descriptors.h" << 'PICOEOF_src_usb_descriptors_h_'
#ifndef USB_DESCRIPTORS_H_
#define USB_DESCRIPTORS_H_

// IR_DONGLE_COMPAT_MODE は CMakeLists.txt のオプションでビルド時に設定される。
// 1 = android-ir-blaster互換モード（VID/PIDをそれになりすます）
// 0 = 独自プロトコルモード（v0.1のテスト用、tools/ir_pico_test.py向け）
#ifndef IR_DONGLE_COMPAT_MODE
#define IR_DONGLE_COMPAT_MODE 1
#endif

#if IR_DONGLE_COMPAT_MODE
// android-ir-blasterのUSBフィルタに合わせる（README記載の2候補のうち0x10C4系）
#define PICO_IR_VID   0x10C4
#define PICO_IR_PID   0x8468
#else
// 独自プロトコル用の安全なVID/PID（Raspberry Pi Foundationの割当VID配下）
#define PICO_IR_VID   0x2E8A
#define PICO_IR_PID   0xF00D
#endif

#endif

PICOEOF_src_usb_descriptors_h_

mkdir -p "$(dirname "src/main.c")"
cat > "src/main.c" << 'PICOEOF_src_main_c_'
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

PICOEOF_src_main_c_

mkdir -p "$(dirname "CMakeLists.txt")"
cat > "CMakeLists.txt" << 'PICOEOF_CMakeLists_txt_'
cmake_minimum_required(VERSION 3.13)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

include(pico_sdk_import.cmake)

project(pico_ir_dongle C CXX ASM)

pico_sdk_init()

# ON = android-ir-blaster互換モード（VID/PIDをなりすまし、実プロトコルで通信）
# OFF = 独自プロトコルモード（tools/ir_pico_test.pyでの動作確認用）
option(IR_DONGLE_COMPAT_MODE "Build in android-ir-blaster compatible mode" ON)

add_executable(pico_ir_dongle
    src/main.c
    src/usb_descriptors.c
    src/ir_tx.c
    src/ir_rx.c
    src/proto.c
    src/proto_compat.c
)

target_compile_definitions(pico_ir_dongle PRIVATE
    IR_DONGLE_COMPAT_MODE=$<BOOL:${IR_DONGLE_COMPAT_MODE}>
)

target_include_directories(pico_ir_dongle PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/src
)

target_link_libraries(pico_ir_dongle PRIVATE
    pico_stdlib
    pico_unique_id
    tinyusb_device
    tinyusb_board
    hardware_pwm
    hardware_gpio
    hardware_irq
    hardware_timer
)

# UF2 / bin / hex 一式を生成
pico_add_extra_outputs(pico_ir_dongle)

# USB経由でのprintfデバッグは無効、UARTのみ（USBはVendorクラス専有のため）
pico_enable_stdio_usb(pico_ir_dongle 0)
pico_enable_stdio_uart(pico_ir_dongle 1)
PICOEOF_CMakeLists_txt_

mkdir -p "$(dirname ".github/workflows/build.yml")"
cat > ".github/workflows/build.yml" << 'PICOEOF__github_workflows_build_yml_'
name: Build firmware.uf2

on:
  push:
    branches: [ "main", "master" ]
    paths:
      - "src/**"
      - "CMakeLists.txt"
      - "pico_sdk_import.cmake"
      - ".github/workflows/build.yml"
  pull_request:
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout this repo
        uses: actions/checkout@v4

      - name: Checkout Pico SDK
        uses: actions/checkout@v4
        with:
          repository: raspberrypi/pico-sdk
          ref: master
          path: pico-sdk
          submodules: recursive

      - name: Install toolchain
        run: |
          sudo apt-get update
          sudo apt-get install -y cmake gcc-arm-none-eabi libnewlib-arm-none-eabi build-essential

      - name: Configure (compat mode / android-ir-blaster互換)
        env:
          PICO_SDK_PATH: ${{ github.workspace }}/pico-sdk
        run: |
          mkdir -p build-compat
          cmake -S . -B build-compat -DPICO_SDK_PATH="$PICO_SDK_PATH" -DIR_DONGLE_COMPAT_MODE=ON

      - name: Build (compat mode)
        run: cmake --build build-compat -j$(nproc)

      - name: Configure (custom protocol mode / ir_pico_test.py用)
        env:
          PICO_SDK_PATH: ${{ github.workspace }}/pico-sdk
        run: |
          mkdir -p build-custom
          cmake -S . -B build-custom -DPICO_SDK_PATH="$PICO_SDK_PATH" -DIR_DONGLE_COMPAT_MODE=OFF

      - name: Build (custom protocol mode)
        run: cmake --build build-custom -j$(nproc)

      - name: Collect firmware files
        run: |
          mkdir -p out
          cp build-compat/pico_ir_dongle.uf2 out/firmware-compat.uf2
          cp build-custom/pico_ir_dongle.uf2 out/firmware-custom.uf2

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: firmware
          path: out/
          if-no-files-found: error
PICOEOF__github_workflows_build_yml_

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

PICOEOF_docs_PROTOCOL_md_

mkdir -p "$(dirname "README.md")"
cat > "README.md" << 'PICOEOF_README_md_'
# Pico IR Dongle (working title)

Raspberry Pi Pico を Android / Windows / Linux 対応の USB 赤外線ドングルにするプロジェクト。
最優先ターゲットは [android-ir-blaster](https://github.com/iodn/android-ir-blaster) との互換。

## 現在地（v0.3）

android-ir-blaster互換のTX側プロトコルが実装済みです（`UsbProtocolFormatter`の実ソース確認済み、詳細は`docs/PROTOCOL.md`）。デフォルトビルドはこの互換モードで、VID/PIDを`0x10C4`/`0x8468`になりすまし、アプリから送られてくるIRコードをそのまま送信できます。

- ✅ USB Vendor/Bulkデバイスとして列挙（互換モード時はandroid-ir-blaster対応VID/PID）
- ✅ android-ir-blasterからのTXコマンドを受信し、38kHzでIR LEDから送信
- ✅ 独自プロトコルモード（`IR_DONGLE_COMPAT_MODE=OFF`でビルド）も引き続き利用可能。`tools/ir_pico_test.py`で単体動作確認できる
- ✅ VS1838Bからの受信をRawタイミングとして取得（独自プロトコル経由のみ、android-ir-blaster互換はまだ）
- ✅ GitHub Actionsで push するたびに両モードの`.uf2`を自動ビルド（Artifactsに`firmware-compat.uf2`と`firmware-custom.uf2`）

## ロードマップ

| バージョン | 内容 |
|---|---|
| v0.1 | USB列挙 / 独自プロトコルでRaw送信 / CI自動ビルド |
| v0.2 | VS1838B受信の安定化、ノイズ除去、複数プロトコルのデコード（NEC等） |
| v0.3 | android-ir-blaster実プロトコル互換（TX側） ← **今ここ** |
| v0.4 | android-ir-blaster Learning Mode互換（RX側）、`UsbIrTransmitter`/`UsbDiscoveryManager`のソース確認が必要 |
| v1.0 | ドキュメント整備、Windows/Linux単体ツールの配布 |

## 未確認事項（v0.4着手前に必要）

TX側は確定済みですが、Learning Mode（受信）側のワイヤーフォーマットはまだ未確認です。`UsbIrTransmitter`と`UsbDiscoveryManager`のソースが確認できれば実装できます。


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
git commit -m "v0.3: android-ir-blaster compat TX protocol implemented"
git push
echo "v0.3 反映完了"

#!/data/data/com.termux/files/usr/bin/bash
# 汎用IR CLIツール(rx/tx/nec/necvariants)の追加
# 必ず Testest リポジトリのディレクトリの中で実行すること
set -e

mkdir -p "$(dirname "src/main_cli.c")"
cat > "src/main_cli.c" << 'PICOEOF_src_main_cli_c_'
// 自由に送受信・解析ができる、シリアル(USB CDC)ベースの汎用IRツール。
// android-ir-blasterのプロトコルとは無関係。Serial USB Terminal等から
// テキストコマンドで直接操作する。
//
// コマンド:
//   help
//   rx [timeout_ms]                受信を1回待つ(デフォルト15000ms)。RAWとNEC解読結果を表示
//   tx <freq_hz> <us1,us2,...>     任意のRAWパターンをそのまま送信(mark始まり)
//   nec <8桁hex>                   標準NEC形式(1byteごとLSBファースト)でエンコードして送信
//   necvariants <8桁hex>           ビット順/バイト順のバリエーションを2秒間隔で連続送信

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include "pico/stdlib.h"
#include "ir_tx.h"
#include "ir_rx.h"

#define GPIO_IR_TX 15
#define GPIO_IR_RX 16
#define LINE_MAX 512
#define PATTERN_MAX 1024

static uint16_t g_pattern[PATTERN_MAX];

// ---- NEC解読（sniffer機能の流用） ----

static bool nec_try_decode(const uint16_t *d, size_t n, uint32_t *addr, uint32_t *cmd) {
    if (n < 2 + 64) return false;
    if (d[0] < 8000 || d[0] > 10500) return false;
    if (d[1] < 4000 || d[1] > 5000) return false;

    uint32_t bits = 0;
    for (int i = 0; i < 32; i++) {
        uint16_t mark = d[2 + i * 2];
        uint16_t space = d[2 + i * 2 + 1];
        if (mark < 400 || mark > 800) return false;
        bool bit;
        if (space > 1300 && space < 2000) bit = true;
        else if (space > 350 && space < 800) bit = false;
        else return false;
        bits = (bits << 1) | (bit ? 1u : 0u);
    }
    *addr = (bits >> 16) & 0xFFFFu;
    *cmd = bits & 0xFFFFu;
    return true;
}

// ---- 受信コマンド ----

static void cmd_rx(uint32_t timeout_ms) {
    printf("受信待機中... (最大%lums、リモコンをVS1838Bに向けて押してください)\r\n", (unsigned long) timeout_ms);

    ir_rx_start(25000);
    absolute_time_t deadline = make_timeout_time_ms(timeout_ms);

    while (true) {
        ir_rx_poll_timeout();
        if (!ir_rx_is_capturing()) break;
        if (time_reached(deadline)) {
            ir_rx_stop();
            break;
        }
        sleep_ms(1);
    }

    uint16_t buf[IR_RX_BUF_LEN];
    size_t n = ir_rx_read(buf, IR_RX_BUF_LEN);

    if (n == 0) {
        printf("受信データなし(タイムアウト)\r\n");
        return;
    }

    printf("---- 受信 %u エントリ (確定までの無信号時間: %lu us) ----\r\n",
           (unsigned) n, (unsigned long) ir_rx_last_idle_gap_us());
    printf("RAW: ");
    for (size_t i = 0; i < n; i++) {
        printf("%u%s", (unsigned) buf[i], (i + 1 < n) ? "," : "");
    }
    printf("\r\n");

    uint32_t addr = 0, cmd = 0;
    if (nec_try_decode(buf, n, &addr, &cmd)) {
        printf("推定プロトコル: NEC addr=0x%04lX cmd=0x%04lX\r\n",
               (unsigned long) addr, (unsigned long) cmd);
    } else {
        printf("推定プロトコル: 不明\r\n");
    }
}

// ---- 生パターン送信コマンド ----

static size_t parse_csv_us(const char *s, uint16_t *out, size_t out_max) {
    size_t n = 0;
    while (*s && n < out_max) {
        char *end;
        long v = strtol(s, &end, 10);
        if (end == s) break;
        if (v < 0) v = 0;
        if (v > 0xFFFF) v = 0xFFFF;
        out[n++] = (uint16_t) v;
        s = end;
        while (*s == ',' || *s == ' ') s++;
    }
    return n;
}

static void cmd_tx(const char *args) {
    char freq_str[32];
    const char *sp = strchr(args, ' ');
    if (!sp) {
        printf("使い方: tx <freq_hz> <us1,us2,...>\r\n");
        return;
    }
    size_t flen = (size_t) (sp - args);
    if (flen >= sizeof(freq_str)) flen = sizeof(freq_str) - 1;
    memcpy(freq_str, args, flen);
    freq_str[flen] = '\0';

    uint32_t freq = (uint32_t) strtoul(freq_str, NULL, 10);
    if (freq == 0) freq = 38000;

    const char *pattern_str = sp + 1;
    size_t n = parse_csv_us(pattern_str, g_pattern, PATTERN_MAX);

    if (n == 0) {
        printf("パターンが空です\r\n");
        return;
    }

    printf("送信中: freq=%luHz entries=%u\r\n", (unsigned long) freq, (unsigned) n);
    ir_tx_send(g_pattern, n, freq);
    printf("送信完了\r\n");
}

// ---- NECエンコード（標準形式: 1byteごとLSBファースト） ----

static size_t nec_encode(uint32_t bytes32, bool lsb_first_per_byte, bool reverse_byte_order,
                          uint16_t *out, size_t out_max) {
    uint8_t b[4];
    b[0] = (uint8_t) (bytes32 >> 24);
    b[1] = (uint8_t) (bytes32 >> 16);
    b[2] = (uint8_t) (bytes32 >> 8);
    b[3] = (uint8_t) (bytes32 >> 0);

    uint8_t order[4];
    if (reverse_byte_order) {
        order[0] = b[3]; order[1] = b[2]; order[2] = b[1]; order[3] = b[0];
    } else {
        order[0] = b[0]; order[1] = b[1]; order[2] = b[2]; order[3] = b[3];
    }

    size_t n = 0;
    if (n < out_max) out[n++] = 9000; // leader mark
    if (n < out_max) out[n++] = 4500; // leader space

    for (int byte_i = 0; byte_i < 4; byte_i++) {
        uint8_t v = order[byte_i];
        for (int bit_i = 0; bit_i < 8; bit_i++) {
            int shift = lsb_first_per_byte ? bit_i : (7 - bit_i);
            bool bit = ((v >> shift) & 1) != 0;
            if (n < out_max) out[n++] = 562; // mark
            if (n < out_max) out[n++] = bit ? 1687 : 562; // space
        }
    }
    if (n < out_max) out[n++] = 562; // trailing mark
    return n;
}

static void cmd_nec(const char *hex) {
    uint32_t v = (uint32_t) strtoul(hex, NULL, 16);
    size_t n = nec_encode(v, true, false, g_pattern, PATTERN_MAX);
    printf("NEC標準形式(LSBファースト/byte順そのまま) を送信: 0x%08lX (entries=%u)\r\n",
           (unsigned long) v, (unsigned) n);
    ir_tx_send(g_pattern, n, 38000);
    printf("送信完了\r\n");
}

static void cmd_necvariants(const char *hex) {
    uint32_t v = (uint32_t) strtoul(hex, NULL, 16);

    struct { bool lsb; bool rev; const char *label; } variants[4] = {
        {true,  false, "LSBファースト / byte順そのまま (標準)"},
        {true,  true,  "LSBファースト / byte順逆転"},
        {false, false, "MSBファースト / byte順そのまま"},
        {false, true,  "MSBファースト / byte順逆転"},
    };

    for (int i = 0; i < 4; i++) {
        size_t n = nec_encode(v, variants[i].lsb, variants[i].rev, g_pattern, PATTERN_MAX);
        printf("[%d/4] %s を送信 (entries=%u)\r\n", i + 1, variants[i].label, (unsigned) n);
        ir_tx_send(g_pattern, n, 38000);
        sleep_ms(2000);
    }
    printf("全パターン送信完了\r\n");
}

static void cmd_help(void) {
    printf("コマンド一覧:\r\n");
    printf("  help                              このヘルプを表示\r\n");
    printf("  rx [timeout_ms]                   受信を1回待つ(デフォルト15000ms)\r\n");
    printf("  tx <freq_hz> <us1,us2,...>         任意のRAWパターンを送信(mark始まり)\r\n");
    printf("  nec <8桁hex>                       標準NEC形式で送信\r\n");
    printf("  necvariants <8桁hex>               ビット順/byte順を4パターン連続送信(2秒間隔)\r\n");
}

// ---- コマンドライン読み取り ----

static void process_line(char *line) {
    while (*line == ' ') line++;
    size_t len = strlen(line);
    while (len > 0 && (line[len - 1] == '\r' || line[len - 1] == '\n' || line[len - 1] == ' ')) {
        line[--len] = '\0';
    }
    if (len == 0) return;

    char *sp = strchr(line, ' ');
    if (sp) *sp = '\0';
    const char *args = sp ? sp + 1 : "";

    if (strcmp(line, "help") == 0) {
        cmd_help();
    } else if (strcmp(line, "rx") == 0) {
        uint32_t timeout_ms = (*args) ? (uint32_t) strtoul(args, NULL, 10) : 15000;
        cmd_rx(timeout_ms);
    } else if (strcmp(line, "tx") == 0) {
        cmd_tx(args);
    } else if (strcmp(line, "nec") == 0) {
        cmd_nec(args);
    } else if (strcmp(line, "necvariants") == 0) {
        cmd_necvariants(args);
    } else {
        printf("不明なコマンド: %s ('help'でコマンド一覧)\r\n", line);
    }
}

int main(void) {
    stdio_init_all();
    ir_tx_init(GPIO_IR_TX);
    ir_rx_init(GPIO_IR_RX);

    sleep_ms(3000);
    printf("\r\n=== Pico IR CLI ===\r\n");
    cmd_help();
    printf("\r\n> ");

    static char line[LINE_MAX];
    size_t pos = 0;

    while (true) {
        int c = getchar_timeout_us(10000);
        if (c == PICO_ERROR_TIMEOUT) continue;

        if (c == '\r' || c == '\n') {
            printf("\r\n");
            line[pos] = '\0';
            process_line(line);
            pos = 0;
            printf("\r\n> ");
        } else if (c == 8 || c == 127) { // backspace/delete
            if (pos > 0) {
                pos--;
                printf("\b \b");
            }
        } else if (pos < LINE_MAX - 1) {
            line[pos++] = (char) c;
            putchar(c);
        }
    }

    return 0;
}
PICOEOF_src_main_cli_c_

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
    ${CMAKE_CURRENT_LIST_DIR}/src/usb_vendor
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

# ---- ハードウェア単体テスト用（USB/プロトコル一切無し。TX点滅+RX検知の両方を確認できる） ----
add_executable(pico_selftest
    src/main_selftest.c
    src/ir_tx.c
    src/ir_rx.c
)

target_include_directories(pico_selftest PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/src
)

target_link_libraries(pico_selftest PRIVATE
    pico_stdlib
    hardware_pwm
    hardware_gpio
    hardware_irq
    hardware_timer
)

pico_add_extra_outputs(pico_selftest)

# ---- IR解析専用ファームウェア（USB CDCシリアルでRAWデータ+NEC解読結果を表示） ----
add_executable(pico_sniffer
    src/main_sniffer.c
    src/ir_rx.c
)

target_include_directories(pico_sniffer PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/src
)

target_link_libraries(pico_sniffer PRIVATE
    pico_stdlib
    hardware_gpio
    hardware_irq
    hardware_timer
)

pico_enable_stdio_usb(pico_sniffer 1)
pico_enable_stdio_uart(pico_sniffer 0)
pico_add_extra_outputs(pico_sniffer)

# ---- 汎用IR CLIツール（USB CDCシリアルで rx/tx/nec コマンドを直接操作） ----
add_executable(pico_cli
    src/main_cli.c
    src/ir_tx.c
    src/ir_rx.c
)

target_include_directories(pico_cli PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/src
)

target_link_libraries(pico_cli PRIVATE
    pico_stdlib
    hardware_pwm
    hardware_gpio
    hardware_irq
    hardware_timer
)

pico_enable_stdio_usb(pico_cli 1)
pico_enable_stdio_uart(pico_cli 0)
pico_add_extra_outputs(pico_cli)
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
          cp build-compat/pico_selftest.uf2 out/firmware-selftest.uf2
          cp build-compat/pico_sniffer.uf2 out/firmware-sniffer.uf2
          cp build-compat/pico_cli.uf2 out/firmware-cli.uf2

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: firmware
          path: out/
          if-no-files-found: error
PICOEOF__github_workflows_build_yml_

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

## LEDが光らない・受信しないときの切り分け

USB/プロトコルを一切介さない、ハードウェア単体テスト用ファームウェアを用意しています。GitHub Actionsの成果物に `firmware-selftest.uf2` として自動生成されます。

これを書き込むと、電源を入れるだけで次の2つが動きます：

- **送信テスト**：IR LED(GP15)が1秒ごとにON/OFFを繰り返す（スマホカメラ越しに見て点滅を確認。可視光LEDに差し替えていれば肉眼でも見える）
- **受信テスト**：VS1838B(GP16)が何か信号を受信するたびに、Pico基板上のLED(GP25)が0.2秒光る（手元のリモコンのボタンを押してみて反応するか確認）

- これで送信側が光る → 送信ハードウェアは正常。ソフトウェア/プロトコル側の問題を疑う
- これでも光らない → 配線・トランジスタの向き・GND共通化をもう一度確認する
- 受信側も合わせて確認できるので、VS1838B側の配線確認にも使えます

## リモコンの生データを見る（firmware-sniffer.uf2）

リモコンが送っている実際のコードを、書き込み直し不要で何度でも確認できる解析専用ファームウェアです。

1. `firmware-sniffer.uf2` をPicoに書き込む
2. AndroidのPlayストアで **「Serial USB Terminal」**（Kai Morich作）のような汎用シリアルターミナルアプリを入れる
3. OTGケーブルでPicoを接続し、アプリでシリアル接続を開く（ボーレートは特に気にしなくてOK、USB CDCなので実際の通信速度に依存しません）
4. リモコンのボタンをVS1838Bに向けて押す
5. 画面に受信したmark/spaceの生データ（RAW）と、NECプロトコルらしき形であればアドレス/コマンドの解読結果が表示される

これで「そもそもどんなコードが飛んできているか」を、android-ir-blasterやこちらの互換プロトコルを一切介さずに確認できます。プロトコル調査や、テレビの正しいコードを探す手がかりに使ってください。

## 自由に送受信・解析する（firmware-cli.uf2）

android-ir-blasterのプロトコルを介さず、Picoを直接コマンドで操作できる汎用ツールです。受信・任意パターン送信・NECエンコード送信が全部これ1つでできます。

1. `firmware-cli.uf2` をPicoに書き込む
2. Serial USB Terminal等でシリアル接続を開く
3. `help` と打つとコマンド一覧が出ます

主なコマンド：
```
rx [timeout_ms]                受信を1回待つ
tx <freq_hz> <us1,us2,...>     任意のRAWパターンを送信
nec <8桁hex>                   標準NEC形式(LSBファースト)で送信
necvariants <8桁hex>           ビット順/byte順を4パターン自動で連続送信
```

`rx`でリモコンのコードを受信し、そこで得たRAWをそのまま`tx`にコピペして送信し直す、といった使い方ができます。`necvariants`は、ビット順の解釈が合っているか分からないときに、4パターン全部を2秒間隔で自動送信するので、テレビの反応を見比べて正しい形式を見つけられます。
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
git commit -m "add general-purpose IR CLI tool (rx/tx/nec/necvariants over USB CDC)"
git push
echo "CLIツール追加 反映完了"

#!/data/data/com.termux/files/usr/bin/bash
# IR解析専用ファームウェア(USB CDCシリアル出力)の追加パッチ
# 必ず Testest リポジトリのディレクトリの中で実行すること
set -e

mkdir -p "$(dirname "src/main_sniffer.c")"
cat > "src/main_sniffer.c" << 'PICOEOF_src_main_sniffer_c_'
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
PICOEOF_src_main_sniffer_c_

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
git commit -m "add IR sniffer firmware with USB CDC serial output (RAW dump + NEC decode)"
git push
echo "snifferファームウェア反映完了"

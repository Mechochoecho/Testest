#!/data/data/com.termux/files/usr/bin/bash
# ハードウェア単体テスト用ファームウェア(TX点滅+RX検知)の追加パッチ
# 必ず Testest リポジトリのディレクトリの中で実行すること
set -e

mkdir -p "$(dirname "src/main_selftest.c")"
cat > "src/main_selftest.c" << 'PICOEOF_src_main_selftest_c_'
// ハードウェア単体テスト用ファームウェア。USB通信は一切行わない。
// 電源を入れるだけで動作する:
//
//   - IR LED(GP15) が 1秒ごとにON/OFFを繰り返す
//     → スマホのカメラ越しに見て、点滅しているか確認する（肉眼では見えない）
//   - VS1838B(GP16) が何かIR信号を受信するたびに、Pico基板上のLED(GP25)が
//     0.2秒だけ光る
//     → 手元のリモコンのボタンを押して、Pico基板上のLEDが反応するか確認する
//
// これでUSB/アプリ側の問題と、配線・ハードウェア側の問題を完全に切り分けられる。

#include "pico/stdlib.h"
#include "ir_tx.h"
#include "ir_rx.h"

#define GPIO_IR_TX 15
#define GPIO_IR_RX 16
#define LED_PIN    25 // Pico基板上のLED

int main(void) {
    stdio_init_all();

    ir_tx_init(GPIO_IR_TX);
    ir_rx_init(GPIO_IR_RX);

    gpio_init(LED_PIN);
    gpio_set_dir(LED_PIN, GPIO_OUT);
    gpio_put(LED_PIN, 0);

    ir_rx_start(20000); // 20ms無信号でキャプチャ完了とみなす

    bool tx_on = false;
    absolute_time_t next_tx_toggle = get_absolute_time();

    while (true) {
        // ---- 送信テスト: 1秒ごとにIR LEDのON/OFFを切り替える ----
        if (absolute_time_diff_us(get_absolute_time(), next_tx_toggle) <= 0) {
            tx_on = !tx_on;
            ir_tx_set_carrier(tx_on);
            next_tx_toggle = delayed_by_ms(get_absolute_time(), 1000);
        }

        // ---- 受信テスト: リモコンの信号を検知したら基板上LEDを光らせる ----
        ir_rx_poll_timeout();
        if (!ir_rx_is_capturing()) {
            uint16_t tmp[64];
            size_t n = ir_rx_read(tmp, 64);
            if (n > 0) {
                gpio_put(LED_PIN, 1);
                sleep_ms(200);
                gpio_put(LED_PIN, 0);
            }
            ir_rx_start(20000); // 次の受信に備える
        }
    }

    return 0;
}
PICOEOF_src_main_selftest_c_

mkdir -p "$(dirname "src/ir_tx.c")"
cat > "src/ir_tx.c" << 'PICOEOF_src_ir_tx_c_'
#include "ir_tx.h"

#include "hardware/pwm.h"
#include "hardware/clocks.h"
#include "hardware/gpio.h"
#include "pico/time.h"

static uint32_t s_pin;
static uint s_slice;
static uint s_chan;
static uint32_t s_cur_freq = 0;

void ir_tx_init(uint32_t gpio_pin) {
    s_pin = gpio_pin;
    gpio_set_function(gpio_pin, GPIO_FUNC_PWM);
    s_slice = pwm_gpio_to_slice_num(gpio_pin);
    s_chan = pwm_gpio_to_channel(gpio_pin);

    ir_tx_set_frequency(38000);
    pwm_set_enabled(s_slice, false);
}

void ir_tx_set_frequency(uint32_t freq_hz) {
    if (freq_hz == 0) freq_hz = 38000;
    if (freq_hz == s_cur_freq) return;

    uint32_t sys_clk = clock_get_hz(clk_sys);

    // wrapが16bitに収まるようclkdivを調整（125MHz sys_clkなら38kHzでdiv=1のままwrap≈3289で余裕）
    float divider = 1.0f;
    uint32_t wrap = (uint32_t)((float) sys_clk / (divider * (float) freq_hz));
    while (wrap > 65535 && divider < 255.0f) {
        divider *= 2.0f;
        wrap = (uint32_t)((float) sys_clk / (divider * (float) freq_hz));
    }
    if (wrap < 2) wrap = 2;

    pwm_set_clkdiv(s_slice, divider);
    pwm_set_wrap(s_slice, (uint16_t)(wrap - 1));
    // デューティ比 約33%（多くのIR LED/受信側の実測値と相性が良い一般的な値）
    pwm_set_chan_level(s_slice, s_chan, (uint16_t)(wrap / 3));

    s_cur_freq = freq_hz;
}

void ir_tx_send(const uint16_t *pattern_us, size_t count, uint32_t freq_hz) {
    if (count == 0) return;
    ir_tx_set_frequency(freq_hz);

    absolute_time_t target = get_absolute_time();

    for (size_t i = 0; i < count; i++) {
        bool is_mark = (i % 2) == 0;
        pwm_set_enabled(s_slice, is_mark);

        target = delayed_by_us(target, pattern_us[i]);
        busy_wait_until(target);
    }

    // 念のため必ず消灯して終了する
    pwm_set_enabled(s_slice, false);
}

void ir_tx_set_carrier(bool on) {
    pwm_set_enabled(s_slice, on);
}
PICOEOF_src_ir_tx_c_

mkdir -p "$(dirname "src/ir_tx.h")"
cat > "src/ir_tx.h" << 'PICOEOF_src_ir_tx_h_'
#ifndef IR_TX_H_
#define IR_TX_H_

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

// IR LED接続ピンを初期化し、PWMキャリアを準備する（送信は無効状態で開始）
void ir_tx_init(uint32_t gpio_pin);

// キャリア周波数を変更する（デフォルト38kHz、10k〜100kHz程度を想定）
void ir_tx_set_frequency(uint32_t freq_hz);

// pattern_us: mark(発光), space(消灯) を交互に並べたマイクロ秒配列。先頭は必ずmark。
// count: pattern_usの要素数
// freq_hz: このパターンで使うキャリア周波数
// ブロッキング関数。呼び出し中はUSB処理が遅延する点に注意（v0.1の既知の制約）。
void ir_tx_send(const uint16_t *pattern_us, size_t count, uint32_t freq_hz);

// キャリアを直接ON/OFFする（タイミング制御なし）。ハードウェアの動作確認用。
void ir_tx_set_carrier(bool on);

#endif
PICOEOF_src_ir_tx_h_

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

# 前回の暫定ファイルが残っていれば削除
rm -f src/main_hwtest.c

git add -A
git commit -m "add hardware-only self test firmware (TX blink + RX onboard LED indicator)"
git push
echo "selftestファームウェア反映完了"

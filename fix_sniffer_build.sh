#!/data/data/com.termux/files/usr/bin/bash
# ビルドエラー修正: tusb_config.hをpico_ir_dongle専用ディレクトリに分離
# (pico_snifferがCDC無効設定を誤って拾ってしまいビルドエラーになる問題の修正)
# 必ず Testest リポジトリのディレクトリの中で実行すること
set -e

# 古い場所にあるtusb_config.hを削除（残っていると混乱の元になるため）
rm -f src/tusb_config.h

mkdir -p "$(dirname "src/usb_vendor/tusb_config.h")"
cat > "src/usb_vendor/tusb_config.h" << 'PICOEOF_src_usb_vendor_tusb_config_h_'
#ifndef _TUSB_CONFIG_H_
#define _TUSB_CONFIG_H_

#ifdef __cplusplus
extern "C" {
#endif

//--------------------------------------------------------------------
// COMMON CONFIGURATION
//--------------------------------------------------------------------
#define CFG_TUSB_MCU               OPT_MCU_RP2040
#define CFG_TUSB_OS                OPT_OS_PICO
#define CFG_TUSB_RHPORT0_MODE      OPT_MODE_DEVICE

#ifndef CFG_TUSB_MEM_SECTION
#define CFG_TUSB_MEM_SECTION
#endif

#ifndef CFG_TUSB_MEM_ALIGN
#define CFG_TUSB_MEM_ALIGN          __attribute__ ((aligned(4)))
#endif

//--------------------------------------------------------------------
// DEVICE CONFIGURATION
//--------------------------------------------------------------------
#ifndef CFG_TUD_ENDPOINT0_SIZE
#define CFG_TUD_ENDPOINT0_SIZE    64
#endif

// Vendorクラスのみ使用（CDC/HID/MSCは不要）
#define CFG_TUD_CDC               0
#define CFG_TUD_MSC               0
#define CFG_TUD_HID               0
#define CFG_TUD_MIDI              0
#define CFG_TUD_VENDOR            1

// Vendorクラスのバッファサイズ。
// TX_RAWのペイロード(最大2048byte, proto.hのCMD_BUF_MAXと一致)と
// RX結果(IR_RX_BUF_LEN*2byte, ir_rx.h)がそのまま収まるように大きめに確保する。
#define CFG_TUD_VENDOR_RX_BUFSIZE  2048
#define CFG_TUD_VENDOR_TX_BUFSIZE  2048

#ifdef __cplusplus
}
#endif

#endif
PICOEOF_src_usb_vendor_tusb_config_h_

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
PICOEOF_CMakeLists_txt_

git add -A
git commit -m "fix: separate tusb_config.h into usb_vendor/ so pico_sniffer stdio_usb build no longer conflicts"
git push
echo "ビルドエラー修正 反映完了"

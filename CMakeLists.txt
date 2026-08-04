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

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


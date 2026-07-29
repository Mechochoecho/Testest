#ifndef USB_DESCRIPTORS_H_
#define USB_DESCRIPTORS_H_

// v0.1〜v0.2: 独自プロトコル用の安全なVID/PID（Raspberry Pi Foundationの割当VID配下）
// v0.3でandroid-ir-blaster互換モードを追加する際は、ビルドオプションで
// VID 0x10C4 / PID 0x8468 (または 0x045E / 0x8468) に切り替える予定。
// 実バイトプロトコルが未確定なうちに互換VID/PIDを名乗ると
// 「認識だけして通信が壊れる」状態になり、かえって混乱するため
// v0.1時点ではあえて名乗らない。
#define PICO_IR_VID   0x2E8A
#define PICO_IR_PID   0xF00D

#endif

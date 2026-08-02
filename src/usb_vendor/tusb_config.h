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

#ifndef PROTO_H_
#define PROTO_H_

#include <stdint.h>

// v0.1 独自プロトコル（android-ir-blaster互換ではない、詳細はdocs/PROTOCOL.md）
// マルチバイト値はすべてリトルエンディアン。

#define CMD_PING        0x01  // -> ACKバイト(0xAA)を返す
#define CMD_TX_RAW      0x02  // freq_hz(u32) + count(u16) + count*duration_us(u16, mark始まり)
#define CMD_RX_START    0x03  // idle_timeout_us(u32)
#define CMD_RX_POLL     0x04  // 引数なし。状態+(完了時)データを返す
#define CMD_RX_STOP     0x05  // 引数なし。強制停止して現在までのデータを返す
#define CMD_GET_VERSION 0x06  // 引数なし。major,minor,patchの3byteを返す

#define FW_VERSION_MAJOR 0
#define FW_VERSION_MINOR 1
#define FW_VERSION_PATCH 0

// main.cのメインループから毎回呼ぶ。USBから届いたバイト列を蓄積し、
// コマンドが揃ったら実行してレスポンスをBulk INに書き込む。
void proto_task(void);

#endif

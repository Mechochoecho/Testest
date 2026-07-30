#ifndef PROTO_COMPAT_H_
#define PROTO_COMPAT_H_

// android-ir-blaster (UsbProtocolFormatter) 互換のTX受信処理。
// メインループから毎回呼ぶこと。応答は一切返さない
// （アプリ側は短いタイムアウトでbulk INを覗きに来るだけで、
//  無ければ諦めて先に進む実装のため、デバイス側からの返答は不要）。
void proto_compat_task(void);

#endif

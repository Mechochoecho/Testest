# Pico IR Dongle (working title)

Raspberry Pi Pico を Android / Windows / Linux 対応の USB 赤外線ドングルにするプロジェクト。
最優先ターゲットは [android-ir-blaster](https://github.com/iodn/android-ir-blaster) との互換。

## 現在地（v0.1）

このコミットで入っているのは **土台** です。android-ir-blaster 互換の通信は
まだ実装していません（理由は下の「未確認事項」参照）。v0.1 でできること：

- Pico が USB Vendor/Bulk デバイスとして列挙される（独自 VID/PID、独自プロトコル）
- ホスト（PC）から Bulk OUT で Raw IR パターンを送ると 38kHz で IR LED から送信される
- VS1838B からの受信パルスを Raw タイミングとして Bulk IN 経由でホストに返す
- `tools/ir_pico_test.py` で Linux/Windows/macOS から動作確認できる（pyusb 使用）
- GitHub Actions で push するたびに `firmware.uf2` を自動ビルドし、Artifacts からダウンロードできる

## ロードマップ

| バージョン | 内容 |
|---|---|
| v0.1 | USB列挙 / 独自プロトコルでRaw送信 / CI自動ビルド ← **今ここ** |
| v0.2 | VS1838B受信の安定化、ノイズ除去、複数プロトコルのデコード（NEC等） |
| v0.3 | android-ir-blaster 実プロトコル互換層（VID/PID偽装 + ハンドシェイク + RLE + 56byte分割） |
| v0.4 | Learning Mode（受信→プレビュー→保存フロー） |
| v1.0 | ドキュメント整備、Windows/Linux単体ツールの配布 |

## 未確認事項（v0.3着手前に必ず潰す）

android-ir-blaster の README（開発者向けメモ）からわかっているのはここまで：

- VID `0x10C4` または `0x045E`、PID `0x8468`、bulk IN/OUT を持つインターフェースが1つ
- オープン時にハンドシェイク → mark/spaceパターンをRLE圧縮 → 56バイト単位に分割してbulk OUT
- 送信後、短時間だけbulk INを読みに行く（バックグラウンドリーダー）
- パターン長が偶数の場合、最後のギャップ長を調整

**ハンドシェイクの実バイト列とRLEの正確なビット/バイトフォーマットは未確認**。これは以下のどちらかで確定させる：

1. `lib/usb/`配下の `UsbProtocolFormatter` の Dartソースを直接読む（一番早い）
2. 対応ドングル実機がある場合、Wireshark + usbmon でアプリ↔ドングル間の実通信をキャプチャする

確定したら `src/proto_compat.c`（v0.3で追加予定）にそのまま落とし込める設計にしてある。

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
Actions タブ → 該当のワークフロー実行 → Artifacts から `firmware.uf2` をダウンロードするだけ。

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

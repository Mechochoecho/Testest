# Pico IR Dongle (working title)

Raspberry Pi Pico を Android / Windows / Linux 対応の USB 赤外線ドングルにするプロジェクト。
最優先ターゲットは [android-ir-blaster](https://github.com/iodn/android-ir-blaster) との互換。

## 現在地（v0.3）

android-ir-blaster互換のTX側プロトコルが実装済みです（`UsbProtocolFormatter`の実ソース確認済み、詳細は`docs/PROTOCOL.md`）。デフォルトビルドはこの互換モードで、VID/PIDを`0x10C4`/`0x8468`になりすまし、アプリから送られてくるIRコードをそのまま送信できます。

- ✅ USB Vendor/Bulkデバイスとして列挙（互換モード時はandroid-ir-blaster対応VID/PID）
- ✅ android-ir-blasterからのTXコマンドを受信し、38kHzでIR LEDから送信
- ✅ 独自プロトコルモード（`IR_DONGLE_COMPAT_MODE=OFF`でビルド）も引き続き利用可能。`tools/ir_pico_test.py`で単体動作確認できる
- ✅ VS1838Bからの受信をRawタイミングとして取得（独自プロトコル経由のみ、android-ir-blaster互換はまだ）
- ✅ GitHub Actionsで push するたびに両モードの`.uf2`を自動ビルド（Artifactsに`firmware-compat.uf2`と`firmware-custom.uf2`）

## ロードマップ

| バージョン | 内容 |
|---|---|
| v0.1 | USB列挙 / 独自プロトコルでRaw送信 / CI自動ビルド |
| v0.2 | VS1838B受信の安定化、ノイズ除去、複数プロトコルのデコード（NEC等） |
| v0.3 | android-ir-blaster実プロトコル互換（TX側） ← **今ここ** |
| v0.4 | android-ir-blaster Learning Mode互換（RX側）、`UsbIrTransmitter`/`UsbDiscoveryManager`のソース確認が必要 |
| v1.0 | ドキュメント整備、Windows/Linux単体ツールの配布 |

## 未確認事項（v0.4着手前に必要）

TX側は確定済みですが、Learning Mode（受信）側のワイヤーフォーマットはまだ未確認です。`UsbIrTransmitter`と`UsbDiscoveryManager`のソースが確認できれば実装できます。


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

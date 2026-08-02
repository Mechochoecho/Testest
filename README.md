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

## リモコンの生データを見る（firmware-sniffer.uf2）

リモコンが送っている実際のコードを、書き込み直し不要で何度でも確認できる解析専用ファームウェアです。

1. `firmware-sniffer.uf2` をPicoに書き込む
2. AndroidのPlayストアで **「Serial USB Terminal」**（Kai Morich作）のような汎用シリアルターミナルアプリを入れる
3. OTGケーブルでPicoを接続し、アプリでシリアル接続を開く（ボーレートは特に気にしなくてOK、USB CDCなので実際の通信速度に依存しません）
4. リモコンのボタンをVS1838Bに向けて押す
5. 画面に受信したmark/spaceの生データ（RAW）と、NECプロトコルらしき形であればアドレス/コマンドの解読結果が表示される

これで「そもそもどんなコードが飛んできているか」を、android-ir-blasterやこちらの互換プロトコルを一切介さずに確認できます。プロトコル調査や、テレビの正しいコードを探す手がかりに使ってください。
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

# v0.1 プロトコル仕様（独自、android-ir-blaster非互換）

USB Vendorクラス、Bulk OUT (EP1 OUT) / Bulk IN (EP1 IN)。マルチバイト値はすべてリトルエンディアン。
VID/PIDは `src/usb_descriptors.h` を参照（デフォルト `0x2E8A:0xF00D`、暫定値）。

## コマンド一覧（Host → Device, Bulk OUT）

| opcode | 名前 | ペイロード | 説明 |
|---|---|---|---|
| 0x01 | PING | なし | 疎通確認 |
| 0x02 | TX_RAW | freq_hz(u32) + count(u16) + count個のduration_us(u16) | IR送信。durationはmark(発光)始まりでmark/space交互 |
| 0x03 | RX_START | idle_timeout_us(u32) | 受信キャプチャ開始 |
| 0x04 | RX_POLL | なし | キャプチャ状態確認（完了していればデータも一緒に返る） |
| 0x05 | RX_STOP | なし | キャプチャ強制終了して結果を取得 |
| 0x06 | GET_VERSION | なし | ファームウェアバージョン取得 |

## レスポンス（Device → Host, Bulk IN）

| opcode | レスポンス |
|---|---|
| PING | `0xAA` の1byte |
| GET_VERSION | major(u8), minor(u8), patch(u8) の3byte |
| TX_RAW | status(u8)。0x00=成功 |
| RX_START | status(u8)。0x00=成功 |
| RX_POLL | done(u8: 0=継続中/1=完了)。done=1のときのみ続けて count(u16) + count個のduration_us(u16) |
| RX_STOP | count(u16) + count個のduration_us(u16)（未完了でもその時点までのデータを返す） |

## 送受信データの意味

- `duration_us` は常に先頭が **mark（発光/信号あり）**、次が **space（消灯/信号なし）**、以降交互。
- VS1838Bはアクティブロー出力のため、受信側ドライバ内部で極性を吸収し、送信側と同じ「mark始まり」の形式に揃えて返す。
- 1エントリの最大値は65535us（それを超える場合はクランプされる。長いギャップの扱いは今後見直す可能性あり）。

## 既知の制約（v0.1時点）

- `ir_tx_send()` はブロッキング実装。送信中はUSB処理が遅延する（他のBulk転送が詰まる可能性あり）。
- タイミング精度はソフトウェアループ依存。USB割り込み等によるジッタは未対策（v0.2以降でPIOオフロードを検討）。
- RX_POLLで完了通知を受け取る前にホストが次のコマンドを送ると未定義動作になる可能性あり（現状は単純なコマンド/レスポンスの逐次処理のみ想定）。

---

# android-ir-blaster 実プロトコル互換（v0.3で実装予定、現時点の判明分のみ）

READMEの開発者向けメモから判明している内容：

- **USBフィルタ**: VID `0x10C4` または `0x045E`、PID `0x8468`。bulk IN/OUTを持つインターフェースが1つ必要。
- **フロー**: オープン時にハンドシェイク → mark/spaceパターンをRLE圧縮 → 56バイト単位に分割してbulk OUTで送信 → 送信後、短時間だけbulk INを読みに行く（バックグラウンドリーダー）。
- **末尾調整**: 偶数長パターンのとき最後のギャップ長を調整してデバイス側の期待値に合わせる。

**未確認**（＝v0.3着手前に必ず確定させる部分）：

- ハンドシェイクの実バイト列（何を送り、何を期待するか）
- RLEの正確なエンコード方式（1エントリ何バイトか、mark/spaceの区別方法、単位、ヘッダの有無）
- 56バイト分割時のパケット単体のヘッダ有無
- Learning Mode時のbulk INデータのフォーマット

### 確定させる方法（優先順）

1. **`UsbProtocolFormatter`（Dart）のソースを直接読む** — GitHubの検索窓からファイルを開いて中身を貼ってもらえれば、そのままこのファイルの続きとして仕様化できる。
2. **実機キャプチャ** — 対応ドングル（Tiqiaa/ZaZa系）実機があれば、Android端末でUSBデバッグ + Wireshark(usbmon経由) or `tcpdump -i usbmon0` でアプリ↔ドングル間の通信をバイト単位でキャプチャする。

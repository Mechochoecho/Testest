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

# android-ir-blaster 実プロトコル互換（v0.3、実装済み・TX側確定）

`UsbProtocolFormatter`（Kotlin, `org.nslabs.ir_blaster`）のソースコードから確認済み。
実装は `src/proto_compat.c`、有効化はデフォルト（`IR_DONGLE_COMPAT_MODE=ON`）。

## USBフィルタ

VID `0x10C4`, PID `0x8468`（README記載の2候補のうち、こちらを採用。`src/usb_descriptors.h`で切替可能）

## 物理フレーム形式

```
0x02, len, eVal, b1, b2, <len-3 バイトのdata>
```

- `len` はこのバイトの直後に続くバイト数（`eVal, b1, b2, data` の合計）
- `eVal` は1〜15を巡回するカウンタ、`fVal` は1〜127を巡回するカウンタ（アプリ側がインクリメントする。デバイス側は単に届いた値をそのまま扱うだけで良い）
- 1フレームは最大 `5 + 56 = 61` バイト（56byte分割はREADMEの記載と一致）

## ハンドシェイクフレーム（len==9固定）

```
eVal, 0x01, 0x01, 'S','T', fVal, 'S','E','N'
```

デバイス側は何も応答しなくてよい。アプリは短いタイムアウト（10〜20ms）でbulk INを覗くだけで、無ければ諦めて先に進む実装になっている。

## TX_RAWフレーム（1個以上のフラグメント、b1=total, b2=index、index=1始まり）

各フラグメントのdataを index=1..total の順に連結すると、以下のpayloadが得られる：

```
'S','T', fVal, 'D', 0x00, <RLE本体...>, 'E','N'
```

### RLE本体のフォーマット

1バイト = 1区間。
- bit7: `1`=mark（発光）, `0`=space（消灯）
- bit6-0: 長さ（16us単位、1〜127＝最大2032us）

127単位（2032us）を超える長さは、**同じ極性のバイトを複数連続**させて表現する（デコード時は同極性が続く限り合算する）。

### 送信パターンの末尾調整（正規化）

送信元がパターンを組み立てる際、パターン長が偶数（＝最後がspace）の場合、最後のspace長を次のように置き換えている：

```
tail = (last_gap_us > 3000) ? (last_gap_us - 3000) : 10
```

これは送信側の処理なので、デバイス側では特に対応不要（届いたRLEをそのままデコードして送信すればよい）。

### 周波数について

**ワイヤー上に周波数情報は一切含まれない。** つまりこのプロトコルに対応するドングルは固定周波数（38kHz）での送信を前提にしている。`src/proto_compat.c` でも38kHz固定として`ir_tx_send()`を呼んでいる。

## 未確認（Learning Mode / RX、v0.4で着手予定）

`UsbIrTransmitter`（実際にbulk転送を行うクラス）と`UsbDiscoveryManager`（デバイス検出・インターフェース取得）、および受信側のフォーマットはまだソースを確認していない。Learning Modeを実装する際は、これらのソースも同様に確認が必要。


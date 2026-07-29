#!/usr/bin/env python3
"""
Pico IR Dongle 動作確認用ホストツール（v0.1 独自プロトコル）

必要: pip install pyusb
Linuxではudevルールで非root権限のアクセスを許可するか、sudoで実行してください。
Windowsではlibusbドライバの割り当てにZadig等が必要な場合があります。

使い方:
  python3 ir_pico_test.py ping
  python3 ir_pico_test.py version
  python3 ir_pico_test.py tx --freq 38000 --pattern 9000,4500,560,560,560,1690
  python3 ir_pico_test.py tx --freq 38000 --file nec_power.csv
  python3 ir_pico_test.py rx --timeout 20000 --wait 15
"""
import argparse
import struct
import sys
import time

import usb.core
import usb.util

VID = 0x2E8A
PID = 0xF00D

CMD_PING = 0x01
CMD_TX_RAW = 0x02
CMD_RX_START = 0x03
CMD_RX_POLL = 0x04
CMD_RX_STOP = 0x05
CMD_GET_VERSION = 0x06


def open_device():
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        sys.exit(f"デバイスが見つかりません (VID=0x{VID:04X} PID=0x{PID:04X})。"
                  f"接続とファームウェア書き込みを確認してください。")

    try:
        if dev.is_kernel_driver_active(0):
            dev.detach_kernel_driver(0)
    except (NotImplementedError, usb.core.USBError):
        pass

    dev.set_configuration()
    cfg = dev.get_active_configuration()
    intf = cfg[(0, 0)]

    ep_out = usb.util.find_descriptor(
        intf,
        custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT)
    ep_in = usb.util.find_descriptor(
        intf,
        custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN)

    if ep_out is None or ep_in is None:
        sys.exit("bulkエンドポイントが見つかりません")

    return dev, ep_out, ep_in


def cmd_ping(ep_out, ep_in):
    ep_out.write(bytes([CMD_PING]))
    resp = ep_in.read(1, timeout=1000)
    if bytes(resp) == b'\xAA':
        print("PING OK")
    else:
        print(f"予期しない応答: {bytes(resp).hex()}")


def cmd_version(ep_out, ep_in):
    ep_out.write(bytes([CMD_GET_VERSION]))
    resp = ep_in.read(3, timeout=1000)
    print(f"firmware version: {resp[0]}.{resp[1]}.{resp[2]}")


def parse_pattern(args):
    if args.file:
        with open(args.file) as f:
            text = f.read()
    elif args.pattern:
        text = args.pattern
    else:
        sys.exit("--pattern か --file のどちらかを指定してください")

    values = [int(x.strip()) for x in text.replace("\n", ",").split(",") if x.strip()]
    if len(values) % 2 != 0:
        print("警告: パターン長が奇数です。末尾に45000usのspaceを追加します。")
        values.append(45000)
    return values


def cmd_tx(ep_out, ep_in, args):
    pattern = parse_pattern(args)
    count = len(pattern)
    payload = struct.pack("<IH", args.freq, count) + struct.pack(f"<{count}H", *pattern)
    ep_out.write(bytes([CMD_TX_RAW]) + payload)
    resp = ep_in.read(1, timeout=5000)
    status = resp[0]
    print(f"TX_RAW status=0x{status:02X} (freq={args.freq}Hz, entries={count})")


def _read_capture_result(ep_in):
    count_resp = ep_in.read(2, timeout=1000)
    count = struct.unpack("<H", bytes(count_resp))[0]
    if count > 0:
        data_resp = ep_in.read(count * 2, timeout=1000)
        values = struct.unpack(f"<{count}H", bytes(data_resp))
        print(f"受信 {count} エントリ:")
        print(",".join(str(v) for v in values))
    else:
        print("受信データなし")


def cmd_rx(ep_out, ep_in, args):
    ep_out.write(bytes([CMD_RX_START]) + struct.pack("<I", args.timeout))
    resp = ep_in.read(1, timeout=1000)
    print(f"RX_START status=0x{resp[0]:02X}  受信待機中...（最大{args.wait}秒、対象のリモコンをVS1838Bに向けて送信してください）")

    deadline = time.time() + args.wait
    while time.time() < deadline:
        ep_out.write(bytes([CMD_RX_POLL]))
        done_resp = ep_in.read(1, timeout=1000)
        if done_resp[0]:
            _read_capture_result(ep_in)
            return
        time.sleep(0.2)

    print("タイムアウト。強制停止して取得します。")
    ep_out.write(bytes([CMD_RX_STOP]))
    _read_capture_result(ep_in)


def main():
    parser = argparse.ArgumentParser(description="Pico IR Dongle v0.1 動作確認ツール")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ping")
    sub.add_parser("version")

    tx_p = sub.add_parser("tx")
    tx_p.add_argument("--freq", type=int, default=38000)
    tx_p.add_argument("--pattern", type=str, help="カンマ区切りのus値(mark始まり)")
    tx_p.add_argument("--file", type=str, help="カンマ区切りのus値が書かれたファイル")

    rx_p = sub.add_parser("rx")
    rx_p.add_argument("--timeout", type=int, default=20000, help="アイドルタイムアウト(us)")
    rx_p.add_argument("--wait", type=int, default=15, help="ホスト側の最大待機秒数")

    args = parser.parse_args()
    dev, ep_out, ep_in = open_device()

    if args.cmd == "ping":
        cmd_ping(ep_out, ep_in)
    elif args.cmd == "version":
        cmd_version(ep_out, ep_in)
    elif args.cmd == "tx":
        cmd_tx(ep_out, ep_in, args)
    elif args.cmd == "rx":
        cmd_rx(ep_out, ep_in, args)


if __name__ == "__main__":
    main()

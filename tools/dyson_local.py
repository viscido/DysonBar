#!/usr/bin/env python3
"""Talk to a Dyson device directly on the LAN (MQTT on port 1883).

    python3 tools/dyson_local.py --host <device-ip> status
    python3 tools/dyson_local.py --host <device-ip> listen [seconds]
    python3 tools/dyson_local.py --host <device-ip> env
    python3 tools/dyson_local.py --host <device-ip> set '{"fnsp":"0004"}'
    python3 tools/dyson_local.py --host <device-ip> raw <topic> '<json>'

Username is the serial, password the decrypted LAN credential saved by
dyson_login.py. Find the IP in your router or via mDNS:
    dns-sd -B _dyson_mqtt._tcp
Whether recent firmware still accepts local clients is an open question,
see docs/PROTOCOL.md - this tool is how to check.
"""
import argparse
import json
import socket
import time

import dysonlib as dl

KEEPALIVE = 20


def pump(sock, seconds):
    end = time.time() + seconds
    sock.settimeout(0.5)
    last_ping, count = time.time(), 0
    while time.time() < end:
        try:
            first, body = dl.read_packet(sock)
        except socket.timeout:
            first = "timeout"
        if first is None:
            print("[-] connection closed by the device")
            break
        if first != "timeout" and first >> 4 == 3:
            topic, payload, packet_id = dl.parse_publish(first, body)
            if packet_id is not None:
                sock.sendall(dl.build_puback(packet_id))
            try:
                pretty = json.dumps(json.loads(payload), indent=2)
            except ValueError:
                pretty = repr(payload[:600])
            print("\n<-- %s\n%s" % (topic, pretty))
            count += 1
        if time.time() - last_ping > KEEPALIVE / 2:
            sock.sendall(dl.PINGREQ)
            last_ping = time.time()
    print("[*] %d message(s)" % count)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["listen", "status", "env", "set", "raw"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--host", required=True, help="device IP address or hostname")
    ap.add_argument("--port", type=int, default=1883)
    ap.add_argument("--serial")
    ap.add_argument("--mqtt31", action="store_true", help="use MQTT 3.1 instead of 3.1.1")
    a = ap.parse_args()

    dev = dl.device(a.serial)
    password = dl.load_json("local_credentials.json").get(dev["serial"])
    if not password:
        raise SystemExit("no LAN credential for %s in the manifest" % dev["serial"])
    rc, message, sock = dl.try_connect(a.host, a.port, "dysonbar-%d" % (int(time.time()) % 100000),
                                       dev["serial"], password, a.mqtt31, timeout=10)
    print("[+] %s:%d -> %s" % (a.host, a.port, message))
    if rc != 0:
        raise SystemExit(1)

    status_topics = "%s/%s/status/#" % (dev["root"], dev["serial"])
    command_topic = "%s/%s/command" % (dev["root"], dev["serial"])
    try:
        sock.sendall(dl.build_subscribe(status_topics))
        if a.command == "listen":
            pump(sock, int(a.args[0]) if a.args else 30)
        elif a.command in ("status", "env"):
            msg = ("REQUEST-CURRENT-STATE" if a.command == "status"
                   else "REQUEST-PRODUCT-ENVIRONMENT-CURRENT-SENSOR-DATA")
            sock.sendall(dl.build_publish(command_topic, json.dumps({"msg": msg, "time": dl.now()}).encode()))
            pump(sock, 10)
        elif a.command == "set":
            data = json.loads(a.args[0])
            payload = {"msg": "STATE-SET", "time": dl.now(), "mode-reason": "LAPP", "data": data}
            sock.sendall(dl.build_publish(command_topic, json.dumps(payload).encode(), qos=1))
            pump(sock, 10)
        else:  # raw
            sock.sendall(dl.build_publish(a.args[0], a.args[1].encode()))
            pump(sock, 5)
    finally:
        try:
            sock.sendall(dl.DISCONNECT)
        except OSError:
            pass
        sock.close()


if __name__ == "__main__":
    main()

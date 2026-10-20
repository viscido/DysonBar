#!/usr/bin/env python3
"""Try CONNECT variants against a Dyson LAN broker and report each answer.

    python3 tools/recon/dyson_auth_matrix.py --host <device-ip> [--serial S]

Uses the decrypted credential saved by dyson_login.py. Each variant changes one
thing (client id, protocol version, password encoding) so the CONNACK codes
show what the broker checks. Read-only: on success it only lists messages.
"""
import argparse
import base64
import os
import socket
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import dysonlib as dl  # noqa: E402


def listen_briefly(sock, root, serial, seconds=8):
    sock.sendall(dl.build_subscribe("%s/%s/status/#" % (root, serial)))
    request = '{"msg": "REQUEST-CURRENT-STATE", "time": "%s"}' % dl.now()
    sock.sendall(dl.build_publish("%s/%s/command" % (root, serial), request.encode()))
    sock.settimeout(0.5)
    end = time.time() + seconds
    while time.time() < end:
        try:
            first, body = dl.read_packet(sock)
        except socket.timeout:
            continue
        if first is None:
            break
        if first >> 4 == 3:
            topic, payload, _ = dl.parse_publish(first, body)
            print("    <-- %s: %r" % (topic, payload[:300]))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, default=1883)
    ap.add_argument("--serial")
    a = ap.parse_args()

    dev = dl.device(a.serial)
    serial, root = dev["serial"], dev["root"]
    password = dl.load_json("local_credentials.json").get(serial)
    if not password:
        raise SystemExit("no LAN credential for %s" % serial)
    print("credential for %s: %s" % (serial, dl.mask(password)))

    variants = [
        ("random id, 3.1.1", "probe-%d" % (int(time.time()) % 9999), serial, password, False),
        ("random id, 3.1", "probe-%d" % (int(time.time()) % 9999), serial, password, True),
        ("serial as id, 3.1.1", serial, serial, password, False),
        ("empty id, 3.1.1", "", serial, password, False),
        ("empty id, 3.1", "", serial, password, True),
        ("no credentials, 3.1.1", "probe-anon", None, None, False),
        ("password without padding", "probe-nopad", serial, password.rstrip("="), False),
        ("password as raw bytes", "probe-raw", serial, base64.b64decode(password), False),
    ]
    for label, client_id, user, pw, mqtt31 in variants:
        rc, message, sock = dl.try_connect(a.host, a.port, client_id, user, pw, mqtt31)
        print("  %-28s -> %s" % (label, message))
        if rc == 0:
            listen_briefly(sock, root, serial)
        if sock:
            sock.close()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Send one MQTT CONNECT and report the broker's answer; on success subscribe
to '#' and print what arrives for a few seconds.

    python3 tools/recon/mqtt_probe.py <host> [--port 1883] [--client-id ID]
                                      [--user U] [--password P] [--mqtt31]
"""
import argparse
import os
import socket
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import dysonlib as dl  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("host")
    ap.add_argument("--port", type=int, default=1883)
    ap.add_argument("--client-id", default="mqtt-probe")
    ap.add_argument("--user")
    ap.add_argument("--password")
    ap.add_argument("--mqtt31", action="store_true")
    ap.add_argument("--listen", type=int, default=5, help="seconds to listen after a successful connect")
    a = ap.parse_args()

    rc, message, sock = dl.try_connect(a.host, a.port, a.client_id, a.user, a.password, a.mqtt31)
    print(message)
    if rc != 0:
        return
    try:
        sock.sendall(dl.build_subscribe("#"))
        sock.settimeout(1)
        end = time.time() + a.listen
        while time.time() < end:
            try:
                first, body = dl.read_packet(sock)
            except socket.timeout:
                continue
            if first is None:
                break
            if first >> 4 == 3:
                topic, payload, _ = dl.parse_publish(first, body)
                print("PUBLISH %s %r" % (topic, payload[:600]))
    finally:
        sock.close()


if __name__ == "__main__":
    main()

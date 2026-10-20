#!/usr/bin/env python3
"""TCP connect scan of one host with light banner grabbing. Only scan devices you own.

    python3 tools/recon/portscan.py <host> [--ports 1-65535] [--workers 120]
"""
import argparse
import socket
from concurrent.futures import ThreadPoolExecutor


def probe(host, port, timeout):
    s = socket.socket()
    s.settimeout(timeout)
    try:
        if s.connect_ex((host, port)) != 0:
            return None
        banner = b""
        try:
            s.settimeout(1.5)
            banner = s.recv(128)
        except OSError:
            pass
        return port, banner[:120]
    finally:
        s.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("host")
    ap.add_argument("--ports", default="1-65535", help="range, e.g. 1-1024")
    ap.add_argument("--workers", type=int, default=120)
    ap.add_argument("--timeout", type=float, default=0.6)
    a = ap.parse_args()
    lo, hi = (int(x) for x in a.ports.split("-"))

    with ThreadPoolExecutor(max_workers=a.workers) as ex:
        found = [r for r in ex.map(lambda p: probe(a.host, p, a.timeout), range(lo, hi + 1)) if r]
    for port, banner in sorted(found):
        print("%d/tcp OPEN  banner=%r" % (port, banner))
    if not found:
        print("no open TCP ports in %s" % a.ports)


if __name__ == "__main__":
    main()

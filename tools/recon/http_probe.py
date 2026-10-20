#!/usr/bin/env python3
"""Check whether open ports on a host speak HTTP or HTTPS (banner grab).

    python3 tools/recon/http_probe.py <host> <port> [<port> ...]
"""
import argparse
import socket
import ssl


def grab(host, port):
    print("=== %d/tcp ===" % port)
    for scheme, use_tls in (("http", False), ("https", True)):
        try:
            s = socket.create_connection((host, port), timeout=3)
            if use_tls:
                s = ssl._create_unverified_context().wrap_socket(s, server_hostname=host)
            s.sendall(("GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n" % host).encode())
            data = b""
            while len(data) < 4096:
                chunk = s.recv(2048)
                if not chunk:
                    break
                data += chunk
            s.close()
            print("[%s] %r" % (scheme, data[:900]) if data else "[%s] connected, no data" % scheme)
        except (OSError, ssl.SSLError) as e:
            print("[%s] error: %s" % (scheme, e))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("host")
    ap.add_argument("ports", nargs="+", type=int)
    a = ap.parse_args()
    for port in a.ports:
        grab(a.host, port)


if __name__ == "__main__":
    main()

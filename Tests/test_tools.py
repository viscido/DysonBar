#!/usr/bin/env python3
"""Offline tests for tools/: no network, no account, no device.

  - dyson_login.py signs in against Tests/fake_dyson.py and stores files 0600
  - the raw MQTT encoder matches paho-mqtt byte for byte (when installed)
  - the LAN credential decrypts after a round trip through openssl
  - dyson_local.py / dyson_auth_matrix.py talk to a strict local fake broker
"""
import base64
import json
import os
import socket
import stat
import subprocess
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(HERE, "..", "tools")
sys.path.insert(0, TOOLS)
home = tempfile.mkdtemp(prefix="dysonbar-test-")
os.environ["DYSON_HOME"] = os.path.join(home, "dyson")
import dysonlib as dl  # noqa: E402

failures = 0


def check(name, ok):
    global failures
    failures += not ok
    print(("PASS " if ok else "FAIL ") + name)


def run_tool(args, stdin="", env=None):
    return subprocess.run([sys.executable, *args], input=stdin, capture_output=True, text=True,
                          env={**os.environ, **(env or {})}, timeout=60)


# ---------------------------------------------------------------- encoder

connect = dl.build_connect("dyson-re-probe", "SERIAL-1", "pw", mqtt31=True)
check("client id length is 2 bytes big-endian", connect[14:16] == b"\x00\x0e")
try:
    import paho.mqtt.client as mqtt

    def paho_bytes(protocol):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        got = {}

        def accept():
            c, _ = srv.accept()
            c.settimeout(2)
            got["first"], got["body"] = dl.read_packet(c)
            c.close()
        t = threading.Thread(target=accept)
        t.start()
        c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="dyson-re-probe", protocol=protocol)
        c.username_pw_set("SERIAL-1", "pw")
        try:
            c.connect("127.0.0.1", srv.getsockname()[1], 20)
            c.loop(timeout=0.5)
        except Exception:
            pass
        t.join()
        srv.close()
        return dl.packet(got["first"], got["body"])

    check("CONNECT 3.1 identical to paho", dl.build_connect("dyson-re-probe", "SERIAL-1", "pw", True)
          == paho_bytes(mqtt.MQTTv31))
    check("CONNECT 3.1.1 identical to paho", dl.build_connect("dyson-re-probe", "SERIAL-1", "pw", False)
          == paho_bytes(mqtt.MQTTv311))
except ImportError:
    print("SKIP paho comparison (paho-mqtt not installed)")

# ---------------------------------------------------------------- decrypt

plain = json.dumps({"serial": "SERIAL-1", "apPasswordHash": "c2VjcmV0LXRlc3Q="}).encode()  # fake, secret-scan: allow
blob = subprocess.run(["/usr/bin/openssl", "enc", "-aes-256-cbc", "-K", dl.LOCAL_KEY_HEX,
                       "-iv", dl.LOCAL_IV_HEX], input=plain, capture_output=True).stdout
cred = dl.decrypt_local_credentials(base64.b64encode(blob).decode())
check("LAN credential round trip", cred == json.loads(plain))

# ---------------------------------------------------------------- login vs fake cloud

fake = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_dyson.py")], stdout=subprocess.PIPE, text=True)
try:
    api_port = int(fake.stdout.readline().split()[1])
    env = {"DYSON_API_BASE": "http://127.0.0.1:%d" % api_port}
    r = run_tool([os.path.join(TOOLS, "dyson_login.py"), "--country", "it"],
                 stdin="user@example.com\n000000\nwrong\n123456\ncorrect horse\n", env=env)
    check("login retries after a wrong code and succeeds", r.returncode == 0 and "not accepted" in r.stdout)
    session = dl.load_json("session.json")
    check("session saved with token and country", session.get("token") == "token-test-1"
          and session.get("country") == "IT")
    stored = open(dl.path("session.json")).read()
    check("password not stored", "horse" not in stored)
    mode = lambda p: stat.S_IMODE(os.stat(p).st_mode)  # noqa: E731
    check("files 0600, folder 0700", mode(dl.path("session.json")) == 0o600
          and mode(dl.path("manifest.json")) == 0o600 and mode(dl.HOME) == 0o700)
    r = run_tool([os.path.join(TOOLS, "dyson_login.py")], stdin="nobody@example.com\n", env=env)
    check("unknown account rejected", r.returncode != 0 and "UNREGISTERED" in (r.stderr + r.stdout))
finally:
    fake.kill()

# ---------------------------------------------------------------- LAN tools vs strict fake broker

SERIAL, PASSWORD = "TST-EU-AAA0001A", "c2VjcmV0LXRlc3Q="
dl.save_json("local_credentials.json", {SERIAL: PASSWORD})
seen = {"connects": [], "subscribed": [], "published": []}


def strict_connect(body):
    """Parse CONNECT strictly (2-byte lengths); None if malformed."""
    try:
        i = 0

        def take():
            nonlocal i
            n = int.from_bytes(body[i:i + 2], "big")
            v = body[i + 2:i + 2 + n]
            if len(v) != n:
                raise ValueError
            i += 2 + n
            return v
        name = take()
        level, flags = body[i], body[i + 1]
        i += 4
        cid = take()
        user = take() if flags & 0x80 else None
        pw = take() if flags & 0x40 else None
        if i != len(body):
            raise ValueError
        return name, level, cid, user, pw
    except (ValueError, IndexError):
        return None


def broker_session(c):
    try:
        first, body = dl.read_packet(c)
        parsed = strict_connect(body)
        seen["connects"].append(parsed)
        ok = parsed and parsed[3] == SERIAL.encode() and parsed[4] == PASSWORD.encode() and parsed[2]
        c.sendall(dl.packet(0x20, bytes([0, 0 if ok else (2 if parsed is None else 4)])))
        if not ok:
            return
        while True:
            first, body = dl.read_packet(c)
            if first is None:
                return
            if first >> 4 == 8:
                tl = int.from_bytes(body[2:4], "big")
                seen["subscribed"].append(body[4:4 + tl].decode())
                c.sendall(dl.packet(0x90, body[0:2] + b"\x00"))
            elif first >> 4 == 3:
                topic, payload, pid = dl.parse_publish(first, body)
                seen["published"].append((topic, json.loads(payload)))
                if pid is not None:
                    c.sendall(dl.build_puback(pid))
                c.sendall(dl.build_publish("527K/%s/status/current" % SERIAL,
                                           b'{"msg":"CURRENT-STATE","product-state":{"fpwr":"OFF"}}'))
            elif first >> 4 == 14:
                return
    except OSError:
        pass
    finally:
        c.close()


srv = socket.socket()
srv.bind(("127.0.0.1", 0))
srv.listen(16)
port = srv.getsockname()[1]
threading.Thread(target=lambda: [threading.Thread(target=broker_session, args=(srv.accept()[0],),
                                                  daemon=True).start() for _ in iter(int, 1)],
                 daemon=True).start()

r = run_tool([os.path.join(TOOLS, "dyson_local.py"), "--host", "127.0.0.1", "--port", str(port), "status"])
check("dyson_local: accepted, subscribed, got state", r.returncode == 0 and "rc=0" in r.stdout
      and "CURRENT-STATE" in r.stdout and seen["subscribed"] == ["527K/%s/status/#" % SERIAL])
check("dyson_local: request sent to command topic",
      seen["published"] and seen["published"][0][0] == "527K/%s/command" % SERIAL)
r = run_tool([os.path.join(TOOLS, "recon", "dyson_auth_matrix.py"), "--host", "127.0.0.1", "--port", str(port)])
check("auth matrix: every CONNECT well-formed", r.returncode == 0 and None not in seen["connects"])
check("auth matrix: password masked in output", PASSWORD not in r.stdout)
r = run_tool([os.path.join(TOOLS, "recon", "mqtt_probe.py"), "127.0.0.1", "--port", str(port)])
check("mqtt_probe: anonymous CONNECT refused (rc=4)", "rc=4" in r.stdout)
r = run_tool([os.path.join(TOOLS, "dyson_decrypt.py"), "--help"])
check("dyson_decrypt --help", r.returncode == 0)

print("ALL PASS" if failures == 0 else "%d FAILED" % failures)
sys.exit(1 if failures else 0)

#!/usr/bin/env python3
"""Fake Dyson cloud for offline tests (stdlib only).

Serves the app API over HTTP and an MQTT 3.1 broker over WebSocket (ws://)
that checks the AWS IoT custom-authorizer headers like the real endpoint.
Prints "API <port> MQTT <port>" on start and serves until killed.

Scripted behaviour the tests rely on:
  - the first IoT credentials issued are "stale": their WebSocket handshake gets 401
  - CURRENT-STATE is sent as QoS 1 and split across two WebSocket frames
  - ENVIRONMENTAL data is sent in one frame together with an unrelated fault message
  - the device ignores STATE-SET for "nmod" (never confirmed)
Admin: POST /admin/kick (drop broker connections), POST /admin/revoke (invalidate
the bearer token), POST /admin/ratelimit (next code request gets 429 with
Retry-After: 2), GET /admin/stats.
"""
import base64
import copy
import hashlib
import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

EMAIL, PASSWORD, OTP, TOKEN = "user@example.com", "correct horse", "123456", "token-test-1"
CLIENT_ID, AUTHORIZER = "client-test-1", "test-authorizer"
ROOT = "527K"
DEVICES = {"TST-EU-AAA0001A": "Kitchen", "TST-EU-BBB0002B": "Living room"}
BASE_STATE = {"fpwr": "ON", "oson": "ON", "hmax": "2972", "hmod": "HEAT", "fnsp": "0004",
              "auto": "OFF", "hflr": "0065", "sltm": "0045", "nmod": "OFF", "rhtm": "OFF",
              "hsta": "HEAT", "fnst": "FAN", "ercd": "NONE"}
BASE_ENV = {"pm25": "0012", "pm10": "0015", "va10": "0034", "hchr": "0012", "hcho": "0002",
            "tact": "2961", "hact": "0045", "noxl": "0003"}

lock = threading.Lock()
devices = {serial: copy.deepcopy(BASE_STATE) for serial in DEVICES}
stats = {"code_requests": 0, "verify_requests": 0, "connects": 0, "rejected": 0, "pubacks": 0, "pings": 0, "iot_calls": 0,
         "subscriptions": [], "commands": [], "errors": []}
flags = {"revoked": False, "ratelimit": 0, "ratelimit_verify": 0}
live = []  # open broker sockets
MQTT_PORT = 0


def error(msg):
    with lock:
        stats["errors"].append(msg)


# ---------------------------------------------------------------- HTTP API

class Api(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, obj=None, headers=None):
        body = json.dumps(obj if obj is not None else {}).encode()
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        if self.headers.get("Content-Type") != "application/json":
            error("missing JSON content type on %s" % self.path)
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def authorized(self):
        return self.headers.get("Authorization") == "Bearer " + TOKEN and not flags["revoked"]

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/admin/stats":
            with lock:
                return self.reply(200, stats)
        if self.headers.get("User-Agent") != "android client":
            return self.reply(403)
        if url.path == "/v1/provisioningservice/application/Android/version":
            return self.reply(200, {"version": "test"})
        if url.path == "/v3/manifest":
            if not self.authorized():
                return self.reply(401)
            devs = [{"serialNumber": s, "name": n, "type": ROOT, "model": "HP09",
                     "connectedConfiguration": {"mqtt": {"remoteBrokerType": "wss",
                                                         "mqttRootTopicLevel": ROOT}}}
                    for s, n in DEVICES.items()]
            devs.append({"serialNumber": "NOT-CONNECTED-1", "name": "Vacuum", "type": "276"})
            return self.reply(200, devs)
        self.reply(404)

    def do_POST(self):
        url = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path == "/admin/kick":
            with lock:
                for s in live:
                    try:
                        s.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
            return self.reply(200)
        if url.path == "/admin/revoke":
            flags["revoked"] = True
            return self.reply(200)
        if url.path == "/admin/ratelimit":
            flags["ratelimit"] = 1
            return self.reply(200)
        if url.path == "/admin/ratelimit-verify":
            flags["ratelimit_verify"] = 1
            return self.reply(200)
        if self.headers.get("User-Agent") != "android client":
            return self.reply(403)
        body = self.body()
        if url.path == "/v3/userregistration/email/userstatus":
            if not query.get("country"):
                error("userstatus without country")
            status = "ACTIVE" if body.get("email") == EMAIL else "UNREGISTERED"
            return self.reply(200, {"accountStatus": status, "authenticationMethod": "EMAIL_PWD_2FA"})
        if url.path == "/v3/userregistration/email/auth":
            if not query.get("culture"):
                error("auth without culture")
            with lock:
                stats["code_requests"] += 1
                limited = flags["ratelimit"] > 0
                flags["ratelimit"] = max(0, flags["ratelimit"] - 1)
            if limited:
                return self.reply(429, {"message": "Too Many Requests"}, {"Retry-After": "2"})
            return self.reply(200, {"challengeId": "challenge-1"})
        if url.path == "/v3/userregistration/email/verify":
            with lock:
                stats["verify_requests"] += 1
                limited = flags["ratelimit_verify"] > 0
                flags["ratelimit_verify"] = 0
            if limited:
                return self.reply(429, {"message": "Too Many Requests"}, {"Retry-After": "2"})
            ok = (body.get("email") == EMAIL and body.get("password") == PASSWORD
                  and body.get("otpCode") == OTP and body.get("challengeId") == "challenge-1")
            if not ok:
                return self.reply(400, {"message": "invalid"})
            return self.reply(200, {"account": "account-test-1", "token": TOKEN, "tokenType": "Bearer"})
        if url.path == "/v2/authorize/iot-credentials":
            if not self.authorized():
                return self.reply(401)
            if body.get("Serial") not in DEVICES:
                error("iot-credentials for unknown serial %r" % body.get("Serial"))
            with lock:
                stats["iot_calls"] += 1
                signature = "stale" if stats["iot_calls"] == 1 else "signature-%d" % stats["iot_calls"]
            return self.reply(200, {
                "IoTCredentials": {"ClientId": CLIENT_ID, "TokenKey": "token", "TokenValue": CLIENT_ID,
                                   "TokenSignature": signature, "CustomAuthorizerName": AUTHORIZER},
                "Endpoint": "127.0.0.1:%d" % MQTT_PORT})
        self.reply(404)


# ---------------------------------------------------------------- MQTT over WebSocket

def mqtt_string(s):
    b = s.encode()
    return len(b).to_bytes(2, "big") + b


def remaining_length(n):
    out = b""
    while True:
        byte, n = n % 128, n // 128
        out += bytes([byte | (0x80 if n else 0)])
        if not n:
            return out


def packet(header, body):
    return bytes([header]) + remaining_length(len(body)) + body


def publish(topic, obj, qos=0, pid=1):
    body = mqtt_string(topic) + (pid.to_bytes(2, "big") if qos else b"") + json.dumps(obj).encode()
    return packet(0x30 | (qos << 1), body)


def ws_frame(payload):
    n = len(payload)
    if n < 126:
        head = bytes([0x82, n])
    elif n < 65536:
        head = bytes([0x82, 126]) + n.to_bytes(2, "big")
    else:
        head = bytes([0x82, 127]) + n.to_bytes(8, "big")
    return head + payload


def recv_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    return data


def read_frame(sock):
    b0, b1 = recv_exact(sock, 2)
    n = b1 & 0x7F
    if n == 126:
        n = int.from_bytes(recv_exact(sock, 2), "big")
    elif n == 127:
        n = int.from_bytes(recv_exact(sock, 8), "big")
    mask = recv_exact(sock, 4) if b1 & 0x80 else None
    data = recv_exact(sock, n)
    if mask:
        data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
    return b0 & 0x0F, data


def handshake(sock):
    raw = b""
    while b"\r\n\r\n" not in raw:
        chunk = sock.recv(4096)
        if not chunk:
            return False
        raw += chunk
    lines = raw.split(b"\r\n\r\n")[0].decode().split("\r\n")
    headers = {k.strip().lower(): v.strip() for k, v in (l.split(":", 1) for l in lines[1:] if ":" in l)}
    if not lines[0].startswith("GET /mqtt "):
        error("bad request line %r" % lines[0])
    if "mqtt" not in headers.get("sec-websocket-protocol", ""):
        error("no mqtt subprotocol")
    authorized = (headers.get("token") == CLIENT_ID
                  and headers.get("x-amz-customauthorizer-name") == AUTHORIZER
                  and headers.get("x-amz-customauthorizer-signature", "stale") != "stale")
    if not authorized:
        with lock:
            stats["rejected"] += 1
        sock.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        return False
    accept = base64.b64encode(hashlib.sha1(
        (headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())  # RFC 6455 GUID, secret-scan: allow
    sock.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                 b"Sec-WebSocket-Accept: " + accept + b"\r\nSec-WebSocket-Protocol: mqtt\r\n\r\n")
    return True


def parse_packets(buf):
    out = []
    while len(buf) >= 2:
        n, mult, i = 0, 1, 1
        while True:
            if i >= len(buf):
                return out, buf
            n += (buf[i] & 0x7F) * mult
            i += 1
            if not buf[i - 1] & 0x80:
                break
            mult *= 128
        if len(buf) < i + n:
            break
        out.append((buf[0], buf[i:i + n]))
        buf = buf[i + n:]
    return out, buf


def broker_session(sock):
    if not handshake(sock):
        sock.close()
        return
    with lock:
        live.append(sock)
    serial = None
    buf = b""
    try:
        while True:
            opcode, data = read_frame(sock)
            if opcode == 8:
                break
            buf += data
            packets, buf = parse_packets(buf)
            for header, body in packets:
                kind = header >> 4
                if kind == 1:  # CONNECT
                    name_len = int.from_bytes(body[0:2], "big")
                    name, level = body[2:2 + name_len], body[2 + name_len]
                    cid_at = 2 + name_len + 4
                    cid_len = int.from_bytes(body[cid_at:cid_at + 2], "big")
                    cid = body[cid_at + 2:cid_at + 2 + cid_len].decode()
                    if (name, level, cid) != (b"MQIsdp", 3, CLIENT_ID):
                        error("bad CONNECT %r" % ((name, level, cid),))
                    with lock:
                        stats["connects"] += 1
                    sock.sendall(ws_frame(packet(0x20, b"\x00\x00")))
                elif kind == 8:  # SUBSCRIBE
                    pid = body[0:2]
                    tl = int.from_bytes(body[2:4], "big")
                    topic = body[4:4 + tl].decode()
                    with lock:
                        stats["subscriptions"].append(topic)
                    serial = topic.split("/")[1]
                    if topic != "%s/%s/status/#" % (ROOT, serial):
                        error("unexpected subscription %r" % topic)
                    sock.sendall(ws_frame(packet(0x90, pid + b"\x00")))
                elif kind == 3:  # PUBLISH
                    qos = (header >> 1) & 3
                    tl = int.from_bytes(body[0:2], "big")
                    topic = body[2:2 + tl].decode()
                    i = 2 + tl
                    if qos:
                        sock.sendall(ws_frame(packet(0x40, body[i:i + 2])))
                        i += 2
                    handle_command(sock, serial, topic, json.loads(body[i:]))
                elif kind == 4:  # PUBACK
                    with lock:
                        stats["pubacks"] += 1
                elif kind == 12:  # PINGREQ
                    with lock:
                        stats["pings"] += 1
                    sock.sendall(ws_frame(b"\xd0\x00"))
                elif kind == 14:  # DISCONNECT
                    return
    except (ConnectionError, OSError, ValueError):
        pass
    finally:
        with lock:
            if sock in live:
                live.remove(sock)
        sock.close()


def handle_command(sock, serial, topic, msg):
    if topic != "%s/%s/command" % (ROOT, serial):
        error("publish to unexpected topic %r" % topic)
        return
    status = "%s/%s/status/current" % (ROOT, serial)
    kind = msg.get("msg")
    if kind == "REQUEST-CURRENT-STATE":
        with lock:
            snap = dict(devices[serial])
        data = publish(status, {"msg": "CURRENT-STATE", "product-state": snap}, qos=1, pid=7)
        half = len(data) // 2
        sock.sendall(ws_frame(data[:half]))  # one MQTT packet across two frames
        sock.sendall(ws_frame(data[half:]))
    elif kind == "REQUEST-PRODUCT-ENVIRONMENT-CURRENT-SENSOR-DATA":
        both = (publish(status, {"msg": "ENVIRONMENTAL-CURRENT-SENSOR-DATA", "data": BASE_ENV})
                + publish("%s/%s/status/fault" % (ROOT, serial), {"msg": "CURRENT-FAULTS", "data": {"x": "1"}}))
        sock.sendall(ws_frame(both))  # two MQTT packets in one frame
    elif kind == "STATE-SET":
        if msg.get("mode-reason") != "LAPP" or "time" not in msg:
            error("STATE-SET without mode-reason/time")
        with lock:
            stats["commands"].append(msg["data"])
            changes = {}
            for k, v in msg["data"].items():
                if k == "nmod":
                    continue  # this fake device ignores night mode
                changes[k] = [devices[serial].get(k), v]
                devices[serial][k] = v
        if changes:
            sock.sendall(ws_frame(publish(status, {"msg": "STATE-CHANGE", "product-state": changes})))


def broker(server):
    while True:
        sock, _ = server.accept()
        threading.Thread(target=broker_session, args=(sock,), daemon=True).start()


def main():
    global MQTT_PORT
    mqtt_server = socket.socket()
    mqtt_server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    mqtt_server.bind(("127.0.0.1", 0))
    mqtt_server.listen(16)
    MQTT_PORT = mqtt_server.getsockname()[1]
    api = ThreadingHTTPServer(("127.0.0.1", 0), Api)
    threading.Thread(target=broker, args=(mqtt_server,), daemon=True).start()
    print("API %d MQTT %d" % (api.server_address[1], MQTT_PORT), flush=True)
    api.serve_forever()


if __name__ == "__main__":
    main()

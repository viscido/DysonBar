"""Shared helpers for the DysonBar command-line tools.

All account data lives in $DYSON_HOME (default ~/.dyson, mode 0700), never in
the repository:
  session.json            bearer token from dyson_login.py (0600)
  manifest.json           device list from the cloud (0600)
  local_credentials.json  decrypted LAN MQTT passwords per serial (0600)

No IPs, serials or countries are hardcoded: the device comes from the manifest
(--serial picks one when the account has several), the LAN address from --host.
"""
import base64
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HOME = os.path.expanduser(os.environ.get("DYSON_HOME", "~/.dyson"))
USER_AGENT = "android client"  # the API rejects other user agents


def api_base(country):
    """Overridable with DYSON_API_BASE (tests point it at a fake server)."""
    if os.environ.get("DYSON_API_BASE"):
        return os.environ["DYSON_API_BASE"].rstrip("/")
    return "https://appapi.cp.dyson.cn" if country.upper() == "CN" else "https://appapi.cp.dyson.com"


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# ---------------------------------------------------------------- storage

def path(name):
    return os.path.join(HOME, name)


def save_json(name, obj):
    os.makedirs(HOME, mode=0o700, exist_ok=True)
    os.chmod(HOME, 0o700)
    target = path(name)
    tmp = target + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=2)
    os.replace(tmp, target)
    return target


def load_json(name):
    try:
        with open(path(name)) as f:
            return json.load(f)
    except FileNotFoundError:
        sys.exit("missing %s - run tools/dyson_login.py first" % path(name))


# ---------------------------------------------------------------- cloud API

def request(method, url_path, country, params=None, body=None, token=None):
    """Returns (status, parsed JSON or raw text)."""
    url = api_base(country) + url_path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("User-Agent", USER_AGENT)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")  # 415 otherwise
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    text = raw.decode(errors="replace")
    try:
        return status, json.loads(text) if text else {}
    except ValueError:
        return status, text


def unlock(country):
    """The API ignores clients that have not called this recently."""
    try:
        request("GET", "/v1/provisioningservice/application/Android/version", country)
    except OSError:
        pass


def session():
    return load_json("session.json")


def device(serial=None):
    """Device record from the saved manifest: {serial, name, root, model}."""
    devices = []
    for d in load_json("manifest.json"):
        mqtt = (d.get("connectedConfiguration") or {}).get("mqtt") or {}
        if not mqtt:
            continue
        devices.append({"serial": d.get("serialNumber"), "name": d.get("name") or d.get("productName"),
                        "root": mqtt.get("mqttRootTopicLevel") or d.get("type"),
                        "model": d.get("model"),
                        "local_credentials": mqtt.get("localBrokerCredentials")})
    if not devices:
        sys.exit("no connected devices in the manifest")
    if serial:
        for d in devices:
            if d["serial"] == serial:
                return d
        sys.exit("serial %s not in the manifest (have: %s)" % (serial, ", ".join(d["serial"] for d in devices)))
    if len(devices) > 1:
        print("several devices, using %s - pick another with --serial (%s)"
              % (devices[0]["serial"], ", ".join(d["serial"] for d in devices)), file=sys.stderr)
    return devices[0]


def iot_credentials(serial):
    """Fresh short-lived AWS IoT credentials (re-fetched for every session)."""
    s = session()
    unlock(s["country"])
    status, body = request("POST", "/v2/authorize/iot-credentials", s["country"],
                           body={"Serial": serial}, token=s["token"])
    if status in (401, 403):
        sys.exit("session expired - run tools/dyson_login.py again")
    if status != 200:
        sys.exit("iot-credentials failed: HTTP %s %s" % (status, str(body)[:200]))
    return body


def iot_client(iot, on_connect, on_message):
    """paho client for the AWS IoT endpoint (MQTT 3.1 over wss + custom authorizer)."""
    import paho.mqtt.client as mqtt
    creds = iot["IoTCredentials"]
    c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=creds["ClientId"],
                    protocol=mqtt.MQTTv31, transport="websockets")
    try:
        import certifi
        c.tls_set(certifi.where())
    except ImportError:
        c.tls_set()
    c.ws_set_options(path="/mqtt", headers={
        creds["TokenKey"]: creds["TokenValue"],
        "X-Amz-CustomAuthorizer-Name": creds["CustomAuthorizerName"],
        "X-Amz-CustomAuthorizer-Signature": creds["TokenSignature"],
    })
    c.on_connect = on_connect
    c.on_message = on_message
    return c


# ---------------------------------------------------------------- LAN credential

LOCAL_KEY_HEX = bytes(range(1, 33)).hex()  # hardcoded in every Dyson client library
LOCAL_IV_HEX = "00" * 16


def decrypt_local_credentials(b64):
    """localBrokerCredentials = base64(AES-256-CBC(key=01..20, iv=0, JSON))."""
    raw = base64.b64decode(b64)
    for extra in ([], ["-nopad"]):
        p = subprocess.run(["/usr/bin/openssl", "enc", "-d", "-aes-256-cbc", *extra,
                            "-K", LOCAL_KEY_HEX, "-iv", LOCAL_IV_HEX],
                           input=raw, capture_output=True)
        if p.returncode == 0:
            text = p.stdout.decode(errors="replace").replace("\b", "").strip()
            try:
                return json.loads(text)
            except ValueError:
                continue
    return None


def mask(secret):
    return "%s...%s (%d chars)" % (secret[:3], secret[-3:], len(secret)) if secret else "-"


# ---------------------------------------------------------------- raw MQTT (LAN tools)
# Strings carry a 2-byte big-endian length; only the fixed header's
# "remaining length" is a variable-length integer.

def remaining_length(n):
    out = b""
    while True:
        byte, n = n % 128, n // 128
        out += bytes([byte | (0x80 if n else 0)])
        if not n:
            return out


def mqtt_string(value):
    b = value if isinstance(value, bytes) else value.encode()
    return len(b).to_bytes(2, "big") + b


def packet(header, body):
    return bytes([header]) + remaining_length(len(body)) + body


def build_connect(client_id, username=None, password=None, mqtt31=False, keepalive=20):
    name, level = (b"MQIsdp", 3) if mqtt31 else (b"MQTT", 4)
    flags = 0x02  # clean session
    payload = mqtt_string(client_id)
    if username is not None:
        flags |= 0x80
        payload += mqtt_string(username)
    if password is not None:
        flags |= 0x40
        payload += mqtt_string(password)
    return packet(0x10, mqtt_string(name) + bytes([level, flags]) + keepalive.to_bytes(2, "big") + payload)


def build_subscribe(topic, packet_id=1, qos=0):
    return packet(0x82, packet_id.to_bytes(2, "big") + mqtt_string(topic) + bytes([qos]))


def build_publish(topic, payload, qos=0, packet_id=1):
    body = mqtt_string(topic) + (packet_id.to_bytes(2, "big") if qos else b"") + payload
    return packet(0x30 | (qos << 1), body)


def build_puback(packet_id):
    return packet(0x40, packet_id.to_bytes(2, "big"))


PINGREQ = b"\xc0\x00"
DISCONNECT = b"\xe0\x00"
CONNACK_CODES = {0: "accepted", 1: "unacceptable protocol version", 2: "identifier rejected",
                 3: "server unavailable", 4: "bad user name or password", 5: "not authorized"}


def read_packet(sock):
    """(first byte, body) or (None, b"") when the connection closes."""
    first = sock.recv(1)
    if not first:
        return None, b""
    length, multiplier = 0, 1
    while True:
        b = sock.recv(1)
        if not b:
            return None, b""
        length += (b[0] & 0x7F) * multiplier
        if not b[0] & 0x80:
            break
        multiplier *= 128
    body = b""
    while len(body) < length:
        chunk = sock.recv(length - len(body))
        if not chunk:
            return None, b""
        body += chunk
    return first[0], body


def parse_publish(first, body):
    """(topic, payload, packet_id or None) of a PUBLISH body."""
    qos = (first >> 1) & 3
    tl = int.from_bytes(body[0:2], "big")
    topic = body[2:2 + tl].decode(errors="replace")
    i = 2 + tl
    packet_id = None
    if qos:
        packet_id = int.from_bytes(body[i:i + 2], "big")
        i += 2
    return topic, body[i:], packet_id


def try_connect(host, port, client_id, username=None, password=None, mqtt31=False, timeout=5):
    """Open a TCP connection and send CONNECT. Returns (rc or None, message, socket)."""
    s = socket.socket()
    s.settimeout(timeout)
    try:
        s.connect((host, port))
        s.sendall(build_connect(client_id, username, password, mqtt31))
        first, body = read_packet(s)
    except OSError as e:
        s.close()
        return None, "error: %s" % e, None
    if first is None:
        s.close()
        return None, "connection closed by broker", None
    if first != 0x20 or len(body) < 2:
        s.close()
        return None, "unexpected packet 0x%02x" % first, None
    rc = body[1]
    return rc, "CONNACK rc=%d (%s)" % (rc, CONNACK_CODES.get(rc, "?")), s

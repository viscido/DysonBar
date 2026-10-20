# Dyson connected-device protocol notes

Unofficial notes on how the MyDyson cloud and Dyson purifiers talk, as used by
DysonBar. Dyson does not document or support this API; it can change at any time.

Status tags:

- **Verified**: tested live against a Purifier Hot+Cool Formaldehyde (HP09,
  topic root `527K`) in October 2026.
- **Community**: taken from the open-source references at the end, not
  re-verified here.
- **Open**: unresolved, see the notes.

## 1. Overview

```
 MyDyson account ──HTTPS──▶ appapi.cp.dyson.com  (sign-in, device list, IoT credentials)
                                   │
 DysonBar / tools ──MQTT over WSS──▶ AWS IoT (custom authorizer) ◀──▶ device
                                                                     │
                                       LAN: MQTT on tcp/1883 ◀───────┘ (status: Open, §6)
```

## 2. Cloud API — **Verified**

Base URL `https://appapi.cp.dyson.com` (`https://appapi.cp.dyson.cn` for China
accounts). Every request needs `User-Agent: android client`; requests with a
body need `Content-Type: application/json` (HTTP 415 otherwise).

| # | Request | Purpose |
|---|---|---|
| 1 | `GET /v1/provisioningservice/application/Android/version` | "Unlocks" the API for the caller's IP; other calls are ignored without a recent call |
| 2 | `POST /v3/userregistration/email/userstatus?country=<CC>` `{"email"}` | `accountStatus` (`ACTIVE`), `authenticationMethod` (e.g. `EMAIL_PWD_2FA`) |
| 3 | `POST /v3/userregistration/email/auth?country=<CC>&culture=<ll-CC>` `{"email"}` | Emails a one-time code; returns `{"challengeId"}`. HTTP 429 = rate limited |
| 4 | `POST /v3/userregistration/email/verify` `{"email","password","challengeId","otpCode"}` | Returns `{"account","token","tokenType":"Bearer"}` |
| 5 | `GET /v3/manifest` (Bearer) | Devices on the account (§3) |
| 6 | `POST /v2/authorize/iot-credentials` (Bearer) `{"Serial"}` | Short-lived AWS IoT credentials for one device (§4) |

`<CC>` is the country of the account (ISO 3166-1 alpha-2); `culture` picks
the language of the code email. The bearer token lasts long but not forever:
calls 5 and 6 return 401/403 once it expires, and you have to sign in again.
The old password-only login (`POST /v2/user/login`) is deprecated.

## 3. Manifest — **Verified**

`GET /v3/manifest` returns an array. Fields used:

| Field | Meaning |
|---|---|
| `serialNumber`, `name`, `model`, `productName` | identity (`name` is the room name set in the app) |
| `type`, `variant` | product type, e.g. `527` + variant `K` |
| `connectedConfiguration.mqtt.mqttRootTopicLevel` | **MQTT topic root**: use this, it can differ from `type` (`527K`, not `527`) |
| `connectedConfiguration.mqtt.remoteBrokerType` | `wss` for the AWS IoT path |
| `connectedConfiguration.mqtt.localBrokerCredentials` | encrypted LAN password (§6) |
| `connectedConfiguration.firmware` | `version`, `autoUpdateEnabled`, `capabilities` (e.g. `EnvironmentalData`, `ExtendedAQ`, `Scheduling`) |

Devices without `connectedConfiguration.mqtt` (e.g. robot vacuums) use other
protocols and are out of scope.

## 4. AWS IoT path — **Verified**

`POST /v2/authorize/iot-credentials` returns:

```json
{
  "Endpoint": "<prefix>-ats.iot.<region>.amazonaws.com",
  "IoTCredentials": {
    "ClientId": "<uuid>", "TokenKey": "token", "TokenValue": "<uuid>",
    "TokenSignature": "<base64>", "CustomAuthorizerName": "<authorizer>"
  }
}
```

Connect with MQTT 3.1 (`MQIsdp`, level 3) over WebSocket:

- URL `wss://<Endpoint>/mqtt` (port 443), subprotocol `mqtt`
- handshake headers (AWS IoT custom authorizer):
  `<TokenKey>: <TokenValue>`, `X-Amz-CustomAuthorizer-Name: <CustomAuthorizerName>`,
  `X-Amz-CustomAuthorizer-Signature: <TokenSignature>`
- MQTT client id = `ClientId`, clean session, no MQTT username/password

The credentials are short-lived: fetch fresh ones for every connection. With
expired ones the WebSocket handshake fails with an HTTP 4xx.

## 5. Topics and messages — **Verified** unless noted

Topic root `<root>` = `mqttRootTopicLevel`.

| Direction | Topic |
|---|---|
| device → client | `<root>/<serial>/status/current` (state, sensor data) |
| device → client | `<root>/<serial>/status/fault` (faults) — **Community** |
| client → device | `<root>/<serial>/command` |

Subscribe to `<root>/<serial>/status/#`, not to the whole `<root>/<serial>/#`
tree: the broker echoes commands back to subscribers of the command topic, and
a client merging every message it receives would mistake its own `STATE-SET`
data for sensor readings.

Commands (JSON on the command topic, `time` in UTC ISO 8601):

```json
{"msg": "REQUEST-CURRENT-STATE", "time": "2026-01-01T12:00:00Z"}
{"msg": "REQUEST-PRODUCT-ENVIRONMENT-CURRENT-SENSOR-DATA", "time": "…"}
{"msg": "STATE-SET", "time": "…", "mode-reason": "LAPP", "data": {"fnsp": "0005"}}
```

`STATE-SET` goes out with QoS 1. The device answers:

- `CURRENT-STATE`: `product-state` with plain values.
- `STATE-CHANGE`: `product-state` values are `[old, new]` pairs. This is how
  you confirm that a write was applied.
- `ENVIRONMENTAL-CURRENT-SENSOR-DATA`: `data` with sensor values. All read
  `OFF` while the fan is off (the sensors run only with airflow).

### `product-state`

| Field | Meaning | Values |
|---|---|---|
| `fpwr` | power | `ON` / `OFF` |
| `fnst` | fan running | `FAN` / `OFF` |
| `fnsp` | fan speed | `0001`–`0010`, `AUTO` |
| `auto` | auto mode | `ON` / `OFF` |
| `oson` / `oscs` | oscillation setting / current state | `ON` / `OFF` |
| `osal`, `osau`, `ancp` | oscillation angles | degrees, 4 digits |
| `nmod` / `nmdv` | night mode / night display level | `ON`/`OFF`, `0001`–… |
| `rhtm` | continuous monitoring | `ON` / `OFF` |
| `hmod` / `hmax` / `hsta` | heat mode / target / heating now | `HEAT`/`OFF`, tenths of kelvin (`2950` = 21.85 °C), `HEAT`/`OFF` |
| `sltm` | sleep timer | minutes (`0030`) or `OFF` |
| `hflr` / `cflr` | HEPA / carbon filter life | percent (`0065`); `INV` if not applicable |
| `hflt` / `cflt` | filter type codes | e.g. `GCOM`, `SCOG` |
| `ercd` / `wacd` | error / warning code | `NONE` or a code shown in the MyDyson app |
| `bril`, `tilt`, `fdir`, `corf`, `psta` | display brightness, tilt sensor, airflow direction, … | |

### Sensor `data`

| Field | Meaning | Scale |
|---|---|---|
| `tact` | temperature | tenths of kelvin |
| `hact` | relative humidity | percent |
| `pm25`, `pm10` | particulate matter | µg/m³ |
| `p25r`, `p10r` | particulate matter, raw | µg/m³ |
| `va10` | VOC index | ×10 — **Community** |
| `noxl` | NO₂ index | ×10 — **Community** |
| `hchr` / `hcho` | formaldehyde (Formaldehyde models) | mg/m³ ×1000 — **Community** |

## 6. LAN — **Open**

- mDNS service `_dyson_mqtt._tcp` → `<serial>.local`, port 1883 (`dns-sd -B _dyson_mqtt._tcp`). **Verified**
- Only tcp/1883 open, no HTTP(S). **Verified** (one HP09)
- Credentials: username = serial, password = `apPasswordHash` from
  `localBrokerCredentials`:
  ```
  base64( AES-256-CBC( key = bytes 0x01..0x20, IV = 16 × 0x00, {"serial","apPasswordHash"} ) )
  ```
  The key is the well-known one in every Dyson client library (`tools/dyson_decrypt.py`). **Verified** (decrypts)

**Whether recent firmware still accepts LAN clients is unresolved.** An earlier
round of probes concluded "LAN closed" (CONNACK `2` for any client id, `4`
with the right password), but those probes encoded MQTT string lengths as
variable-length integers instead of 2-byte big-endian. That malformed packet
explains both codes by itself. A packet capture "showing" that the phone app
never uses the LAN was also inconclusive: it was taken on a third host, which
cannot see phone↔device traffic on a switched or Wi-Fi network. To settle it,
run the corrected tools:

```bash
python3 tools/dyson_local.py --host <device-ip> status
python3 tools/recon/dyson_auth_matrix.py --host <device-ip>
```

## 7. References

- [libdyson-wg/appapi](https://github.com/libdyson-wg/appapi): OpenAPI description of the cloud API
- [shenxn/libdyson](https://github.com/shenxn/libdyson): Python library, field meanings and scales
- [libdyson-wg/opendyson](https://github.com/libdyson-wg/opendyson): Go CLI, manifest parsing, IoT headers
- [libdyson-wg/ha-dyson-cloud](https://github.com/libdyson-wg/ha-dyson-cloud): Home Assistant integration

#!/usr/bin/env python3
"""Control a Dyson device through the cloud (AWS IoT), like the MyDyson app.

    python3 tools/dyson_iot.py status                 # current state + sensors
    python3 tools/dyson_iot.py listen [seconds]       # print device messages
    python3 tools/dyson_iot.py set '{"fnsp":"0005"}'  # STATE-SET
    python3 tools/dyson_iot.py selftest               # reversible write test

Options: --serial <serial> when the account has several devices.
Needs: pip install --user "paho-mqtt>=2.0" certifi, and tools/dyson_login.py once.
"""
import argparse
import json
import threading
import time

import dysonlib as dl

WATCH = ("fpwr", "fnst", "fnsp", "oson", "oscs", "nmod", "hmod", "hsta")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["status", "listen", "set", "selftest"])
    ap.add_argument("arg", nargs="?", help="seconds for listen, JSON data for set")
    ap.add_argument("--serial")
    args = ap.parse_args()

    dev = dl.device(args.serial)
    status_topics = "%s/%s/status/#" % (dev["root"], dev["serial"])
    command_topic = "%s/%s/command" % (dev["root"], dev["serial"])
    connected = threading.Event()
    brief = args.command == "selftest"

    def on_connect(client, userdata, flags, reason_code, properties):
        print("[iot] connect: %s" % reason_code)
        if not reason_code.is_failure:
            client.subscribe(status_topics)
            connected.set()

    def on_message(client, userdata, msg):
        try:
            m = json.loads(msg.payload)
        except ValueError:
            print("<-- %s %r" % (msg.topic, msg.payload[:300]))
            return
        if brief:
            ps = m.get("product-state") or {}
            print("    [%s] %s" % (m.get("msg"), json.dumps({k: ps[k] for k in WATCH if k in ps})))
        else:
            print("\n<-- %s\n%s" % (msg.topic, json.dumps(m, indent=2)))

    iot = dl.iot_credentials(dev["serial"])
    client = dl.iot_client(iot, on_connect, on_message)
    print("[iot] connecting to the Dyson cloud for %s (%s)..." % (dev["name"], dev["serial"]))
    client.connect(iot["Endpoint"], 443, 30)
    client.loop_start()
    if not connected.wait(15):
        client.loop_stop()
        raise SystemExit("[iot] could not connect")

    def send(msg, data=None):
        payload = {"msg": msg, "time": dl.now()}
        if data is not None:
            payload["mode-reason"] = "LAPP"
            payload["data"] = data
        client.publish(command_topic, json.dumps(payload), qos=1 if data is not None else 0)
        print("[>] %s %s" % (msg, json.dumps(data) if data is not None else ""))

    try:
        if args.command == "status":
            send("REQUEST-CURRENT-STATE")
            send("REQUEST-PRODUCT-ENVIRONMENT-CURRENT-SENSOR-DATA")
            time.sleep(8)
        elif args.command == "listen":
            time.sleep(int(args.arg or 30))
        elif args.command == "set":
            if not args.arg:
                raise SystemExit("set needs JSON data, e.g. '{\"oson\":\"ON\"}'")
            send("STATE-SET", json.loads(args.arg))
            time.sleep(8)
        else:  # selftest: toggle oscillation and restore it
            send("REQUEST-CURRENT-STATE")
            time.sleep(5)
            for value in ("OFF", "ON"):
                send("STATE-SET", {"oson": value})
                time.sleep(6)
            print("[iot] selftest done - oscillation restored to ON")
    finally:
        client.disconnect()
        client.loop_stop()


if __name__ == "__main__":
    main()

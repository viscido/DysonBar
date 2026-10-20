#!/usr/bin/env python3
"""Decrypt the LAN MQTT credential (localBrokerCredentials) from a manifest.

    python3 tools/dyson_decrypt.py [manifest.json] [--show]

Defaults to $DYSON_HOME/manifest.json. Passwords are masked unless --show.
Format: base64(AES-256-CBC(key = bytes 1..32, IV = 16 zero bytes, JSON)).
"""
import argparse
import json

import dysonlib as dl


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("manifest", nargs="?", default=dl.path("manifest.json"))
    ap.add_argument("--show", action="store_true", help="print the full password")
    args = ap.parse_args()

    with open(args.manifest) as f:
        devices = json.load(f)
    for d in devices:
        mqtt = (d.get("connectedConfiguration") or {}).get("mqtt") or {}
        print("%s (%s) model %s, topic root %s" % (d.get("name"), d.get("serialNumber"),
                                                  d.get("model"), mqtt.get("mqttRootTopicLevel")))
        blob = mqtt.get("localBrokerCredentials")
        if not blob:
            print("  no localBrokerCredentials")
            continue
        cred = dl.decrypt_local_credentials(blob) or {}
        password = cred.get("apPasswordHash")
        print("  username %s  password %s" % (cred.get("serial"),
                                              password if args.show else dl.mask(password)))


if __name__ == "__main__":
    main()

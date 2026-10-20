#!/usr/bin/env python3
"""Sign in to the Dyson cloud (email + one-time code) and save the session.

    python3 tools/dyson_login.py [--country IT]

Asks for the account email, emails a one-time code, then asks for the code and
the password (hidden; sent once, never stored). Saves to $DYSON_HOME (~/.dyson):
session.json (bearer token), manifest.json (devices) and
local_credentials.json (decrypted LAN MQTT passwords, see docs/PROTOCOL.md).
"""
import argparse
import getpass
import locale
import sys

import dysonlib as dl


def default_country():
    loc = (locale.getlocale()[0] or "en_US").replace("-", "_")
    return loc.split("_")[-1].upper() if "_" in loc else "US"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--country", default=default_country(),
                    help="country of the Dyson account, ISO code (default: from locale)")
    ap.add_argument("--language", default="en", help="language of the code email (default: en)")
    args = ap.parse_args()
    country = args.country.upper()
    culture = "%s-%s" % (args.language.lower(), country)

    email = input("Dyson account email: ").strip()
    if "@" not in email:
        sys.exit("an email address is required")

    dl.unlock(country)
    status, body = dl.request("POST", "/v3/userregistration/email/userstatus", country,
                              params={"country": country}, body={"email": email})
    if status != 200:
        sys.exit("userstatus failed: HTTP %s %s" % (status, str(body)[:200]))
    if body.get("accountStatus") != "ACTIVE":
        sys.exit("account status is %r - check the email and --country" % body.get("accountStatus"))

    status, body = dl.request("POST", "/v3/userregistration/email/auth", country,
                              params={"country": country, "culture": culture}, body={"email": email})
    if status == 429:
        sys.exit("rate-limited by Dyson - wait a few minutes")
    if status != 200 or "challengeId" not in body:
        sys.exit("could not request a code: HTTP %s %s" % (status, str(body)[:200]))
    challenge = body["challengeId"]
    print("Dyson has emailed a one-time code to %s." % email)

    for _ in range(3):
        otp = input("Code from the email: ").strip()
        password = getpass.getpass("Dyson account password (hidden, not stored): ")
        status, body = dl.request("POST", "/v3/userregistration/email/verify", country,
                                  params={"country": country, "culture": culture},
                                  body={"email": email, "password": password,
                                        "challengeId": challenge, "otpCode": otp})
        password = None
        if status == 200 and body.get("token"):
            break
        print("not accepted (HTTP %s) - try again" % status)
    else:
        sys.exit("sign-in failed")

    token = body["token"]
    dl.save_json("session.json", {"email": email, "country": country,
                                  "account": body.get("account"), "token": token})

    status, devices = dl.request("GET", "/v3/manifest", country, token=token)
    if status != 200:
        sys.exit("manifest failed: HTTP %s" % status)
    dl.save_json("manifest.json", devices)

    local = {}
    print("\nDevices:")
    for d in devices:
        mqtt = (d.get("connectedConfiguration") or {}).get("mqtt") or {}
        print("  %-20s %-16s model %-6s topic root %s" % (d.get("name"), d.get("serialNumber"),
                                                         d.get("model"), mqtt.get("mqttRootTopicLevel")))
        if mqtt.get("localBrokerCredentials"):
            cred = dl.decrypt_local_credentials(mqtt["localBrokerCredentials"])
            if cred and cred.get("apPasswordHash"):
                local[d["serialNumber"]] = cred["apPasswordHash"]
    if local:
        dl.save_json("local_credentials.json", local)
    print("\nSaved session, manifest%s in %s (owner-only permissions)."
          % (" and LAN credentials" if local else "", dl.HOME))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("\naborted")

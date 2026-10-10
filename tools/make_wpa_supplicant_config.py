#!/usr/bin/env python3
"""Read SSID and passphrase from stdin and emit a WPA-PSK config."""

import hashlib
import re
import sys


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


ssid = sys.stdin.readline().rstrip("\r\n")
passphrase = sys.stdin.readline().rstrip("\r\n")
ssid_bytes = ssid.encode("utf-8")
passphrase_bytes = passphrase.encode("utf-8")

if not ssid_bytes or len(ssid_bytes) > 32:
    fail("SSID must contain 1 to 32 UTF-8 bytes.")
if any(ord(char) < 0x20 or ord(char) == 0x7f for char in ssid):
    fail("SSID must not contain control characters.")

if re.fullmatch(r"[0-9a-fA-F]{64}", passphrase):
    psk = passphrase.lower()
elif 8 <= len(passphrase_bytes) <= 63:
    psk = hashlib.pbkdf2_hmac(
        "sha1", passphrase_bytes, ssid_bytes, 4096, dklen=32
    ).hex()
else:
    fail("Password must be 8–63 UTF-8 bytes, or a 64-digit hexadecimal PSK.")

quoted_ssid = '"' + ssid.replace("\\", "\\\\").replace('"', '\\"') + '"'
sys.stdout.write(
    "update_config=0\n\n"
    "network={\n"
    f"\tssid={quoted_ssid}\n"
    f"\tpsk={psk}\n"
    "\tkey_mgmt=WPA-PSK\n"
    "}\n"
)

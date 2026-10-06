#!/usr/bin/env python3
"""Independent check of a signed update: verifies the appcast's EdDSA signature over the zip
against the SUPublicEDKey baked into the app's Info.plist (not the key derived from the secret),
and that the enclosure length matches. Needs `cryptography`.

    verify-update.py <Info.plist> <appcast.xml> <zip>
"""
import base64, plistlib, sys
import xml.etree.ElementTree as ET
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
plist_path, appcast_path, zip_path = sys.argv[1:4]
public_key = base64.b64decode(plistlib.load(open(plist_path, "rb"))["SUPublicEDKey"])
enclosure = ET.parse(appcast_path).getroot().find("channel/item/enclosure")
signature = base64.b64decode(enclosure.get(SPARKLE + "edSignature"))
data = open(zip_path, "rb").read()
if int(enclosure.get("length")) != len(data):
    sys.exit(f"length mismatch: appcast {enclosure.get('length')} vs file {len(data)}")
Ed25519PublicKey.from_public_bytes(public_key).verify(signature, data)  # raises if invalid
print(f"OK: {zip_path} ({len(data)} bytes) verifies against SUPublicEDKey")

#!/usr/bin/env python3
"""
Generate a SpotlessMac license key signed with your Ed25519 private key.

Usage:
    python3 sign-license.py user@example.com

Output:
    A single line — the license key to deliver to the customer.

Setup:
    pip install cryptography

Key generation (run once, keep license_private.pem secret):
    openssl genpkey -algorithm ed25519 -out license_private.pem
    openssl pkey -in license_private.pem -pubout -out license_public.pem
    # Extract raw 32-byte public key for embedding in LicenseValidator.swift:
    openssl pkey -in license_public.pem -pubin -outform DER | tail -c 32 | xxd -i

Webhook integration (Lemon Squeezy / Gumroad):
    - Call this script (or inline the logic) in your purchase webhook handler.
    - Pass the buyer's email and write the returned key to the order confirmation.
    - TODO: point PRIVATE_KEY_PATH to wherever you store the private key on your server.
"""

import sys
import base64
from datetime import date
from pathlib import Path

# TODO: set this to the path of your private key file on the server.
# Never commit license_private.pem to git.
PRIVATE_KEY_PATH = Path(__file__).parent / "license_private.pem"

PRODUCT_ID = "spotlessmac-v1"


def create_license(email: str) -> str:
    try:
        from cryptography.hazmat.primitives.serialization import load_pem_private_key
    except ImportError:
        sys.exit("ERROR: run 'pip install cryptography' first.")

    if not PRIVATE_KEY_PATH.exists():
        sys.exit(f"ERROR: private key not found at {PRIVATE_KEY_PATH}")

    payload = f"{email}|{PRODUCT_ID}|{date.today().isoformat()}".encode()

    with open(PRIVATE_KEY_PATH, "rb") as f:
        private_key = load_pem_private_key(f.read(), password=None)

    signature = private_key.sign(payload)  # type: ignore[attr-defined]

    return (
        base64.b64encode(payload).decode()
        + "."
        + base64.b64encode(signature).decode()
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"Usage: {sys.argv[0]} user@example.com")
    print(create_license(sys.argv[1]))

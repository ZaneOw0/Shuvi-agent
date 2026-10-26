import base64
import json
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


def main():
    request = json.load(sys.stdin)
    if not isinstance(request, dict) or set(request) != {
        "schemaVersion", "publicKey", "message", "signature"
    }:
        raise ValueError("invalid request")
    if request["schemaVersion"] != 1:
        raise ValueError("invalid schema")

    public_key = base64.b64decode(request["publicKey"], validate=True)
    message = base64.b64decode(request["message"], validate=True)
    signature = base64.b64decode(request["signature"], validate=True)
    if len(public_key) != 32 or len(signature) != 64 or len(message) > 8 * 1024 * 1024:
        raise ValueError("invalid input")

    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(signature, message)
    except InvalidSignature:
        print('{"schemaVersion":1,"valid":false}')
        return 21

    print('{"schemaVersion":1,"valid":true}')
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, TypeError, KeyError, json.JSONDecodeError):
        print('{"schemaVersion":1,"valid":false}')
        raise SystemExit(20)

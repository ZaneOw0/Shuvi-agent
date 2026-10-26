import base64
import json
import os
import sys

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.argon2 import Argon2id


SCHEMA_VERSION = 1
KIND = "encrypted"
KDF_ALGORITHM = "argon2id"
CIPHER_ALGORITHM = "aes-256-gcm"
KEY_LENGTH = 32
ITERATIONS = 3
LANES = 4
MEMORY_KIB = 65536
MAX_INPUT = 4 * 1024 * 1024


def exact_keys(value, expected):
    return isinstance(value, dict) and set(value.keys()) == set(expected)


def decode(value, expected_length=None):
    if not isinstance(value, str):
        raise ValueError("invalid base64")
    decoded = base64.b64decode(value, validate=True)
    if expected_length is not None and len(decoded) != expected_length:
        raise ValueError("invalid length")
    return decoded


def aad(salt, nonce):
    header = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": KIND,
        "kdf": {
            "algorithm": KDF_ALGORITHM,
            "length": KEY_LENGTH,
            "iterations": ITERATIONS,
            "lanes": LANES,
            "memoryKiB": MEMORY_KIB,
            "salt": base64.b64encode(salt).decode("ascii"),
        },
        "cipher": {
            "algorithm": CIPHER_ALGORITHM,
            "nonce": base64.b64encode(nonce).decode("ascii"),
        },
    }
    return json.dumps(header, sort_keys=True, separators=(",", ":")).encode("utf-8")


def derive(passphrase, salt):
    encoded = passphrase.encode("utf-8")
    if len(passphrase) < 12 or len(passphrase) > 1024 or len(encoded) > 4096:
        raise ValueError("invalid passphrase")
    return Argon2id(
        salt=salt,
        length=KEY_LENGTH,
        iterations=ITERATIONS,
        lanes=LANES,
        memory_cost=MEMORY_KIB,
    ).derive(encoded)


def encrypt(request):
    if not exact_keys(request, ("schemaVersion", "operation", "passphrase", "plaintext")):
        raise ValueError("invalid request")
    if request["schemaVersion"] != SCHEMA_VERSION or request["operation"] != "encrypt":
        raise ValueError("invalid request")
    plaintext = decode(request["plaintext"])
    if not plaintext or len(plaintext) > MAX_INPUT:
        raise ValueError("invalid plaintext")
    salt = os.urandom(16)
    nonce = os.urandom(12)
    key = derive(request["passphrase"], salt)
    ciphertext = AESGCM(key).encrypt(nonce, plaintext, aad(salt, nonce))
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": KIND,
        "kdf": {
            "algorithm": KDF_ALGORITHM,
            "salt": base64.b64encode(salt).decode("ascii"),
            "length": KEY_LENGTH,
            "iterations": ITERATIONS,
            "lanes": LANES,
            "memoryKiB": MEMORY_KIB,
        },
        "cipher": {
            "algorithm": CIPHER_ALGORITHM,
            "nonce": base64.b64encode(nonce).decode("ascii"),
            "ciphertext": base64.b64encode(ciphertext).decode("ascii"),
        },
    }


def decrypt(request):
    if not exact_keys(request, ("schemaVersion", "operation", "passphrase", "envelope")):
        raise ValueError("invalid request")
    if request["schemaVersion"] != SCHEMA_VERSION or request["operation"] != "decrypt":
        raise ValueError("invalid request")
    envelope = request["envelope"]
    if not exact_keys(envelope, ("schemaVersion", "kind", "kdf", "cipher")):
        raise ValueError("invalid envelope")
    kdf = envelope["kdf"]
    cipher = envelope["cipher"]
    if (
        envelope["schemaVersion"] != SCHEMA_VERSION
        or envelope["kind"] != KIND
        or not exact_keys(kdf, ("algorithm", "salt", "length", "iterations", "lanes", "memoryKiB"))
        or not exact_keys(cipher, ("algorithm", "nonce", "ciphertext"))
        or kdf["algorithm"] != KDF_ALGORITHM
        or kdf["length"] != KEY_LENGTH
        or kdf["iterations"] != ITERATIONS
        or kdf["lanes"] != LANES
        or kdf["memoryKiB"] != MEMORY_KIB
        or cipher["algorithm"] != CIPHER_ALGORITHM
    ):
        raise ValueError("unsupported envelope")
    salt = decode(kdf["salt"], 16)
    nonce = decode(cipher["nonce"], 12)
    ciphertext = decode(cipher["ciphertext"])
    if len(ciphertext) < 16 or len(ciphertext) > MAX_INPUT + 16:
        raise ValueError("invalid ciphertext")
    key = derive(request["passphrase"], salt)
    plaintext = AESGCM(key).decrypt(nonce, ciphertext, aad(salt, nonce))
    return {
        "schemaVersion": SCHEMA_VERSION,
        "plaintext": base64.b64encode(plaintext).decode("ascii"),
    }


def main():
    raw = sys.stdin.buffer.read(MAX_INPUT * 2 + 1)
    if not raw or len(raw) > MAX_INPUT * 2:
        raise ValueError("invalid input")
    request = json.loads(raw)
    operation = request.get("operation") if isinstance(request, dict) else None
    result = encrypt(request) if operation == "encrypt" else decrypt(request)
    sys.stdout.write(json.dumps(result, sort_keys=True, separators=(",", ":")))


try:
    main()
except InvalidTag:
    sys.stdout.write('{"error":"authentication_failed"}')
    sys.exit(21)
except Exception:
    sys.stdout.write('{"error":"invalid_request"}')
    sys.exit(20)

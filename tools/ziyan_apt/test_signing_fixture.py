"""Disposable OpenPGP v4 test signer. Not used by publishing code.

Wire format: RFC 4880 sections 4.2, 5.2.3, 5.2.4, 5.5.2 and 7.
GPG independently verifies the packets generated here. No secret key is saved.
"""
import base64
import hashlib
import time
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa


def packet(tag, body):
    return bytes([0xC0 | tag, 255]) + len(body).to_bytes(4, "big") + body


def mpi(value):
    return value.bit_length().to_bytes(2, "big") + value.to_bytes((value.bit_length() + 7) // 8, "big")


class TestSigner:
    def __init__(self):
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.created = int(time.time()).to_bytes(4, "big")
        numbers = self.key.public_key().public_numbers()
        body = b"\x04" + self.created + b"\x01" + mpi(numbers.n) + mpi(numbers.e)
        prefixed_key = b"\x99" + len(body).to_bytes(2, "big") + body
        self.fingerprint = hashlib.sha1(prefixed_key).digest()
        user = b"ZiYan disposable fixture <fixture@example.invalid>"
        certification = prefixed_key + b"\xb4" + len(user).to_bytes(4, "big") + user
        self.public_keyring = packet(6, body) + packet(13, user) + self.sign(certification, 0x13)

    def sign(self, data, signature_type=0):
        hashed_subpackets = b"\x05\x02" + self.created
        header = bytes([4, signature_type, 1, 8]) + len(hashed_subpackets).to_bytes(2, "big") + hashed_subpackets
        signed = data + header + b"\x04\xff" + len(header).to_bytes(4, "big")
        digest = hashlib.sha256(signed).digest()
        signature = self.key.sign(signed, padding.PKCS1v15(), hashes.SHA256())
        issuer = b"\x09\x10" + self.fingerprint[-8:]
        body = header + len(issuer).to_bytes(2, "big") + issuer + digest[:2] + mpi(int.from_bytes(signature, "big"))
        return packet(2, body)

    def clearsign(self, data):
        # Cleartext signatures exclude the final line ending before armor.
        canonical = b"\r\n".join(line.rstrip(b" \t") for line in data.rstrip(b"\n").split(b"\n"))
        signature = self.sign(canonical, 1)
        crc = 0xB704CE
        for octet in signature:
            crc ^= octet << 16
            for _ in range(8):
                crc <<= 1
                if crc & 0x1000000:
                    crc ^= 0x1864CFB
        armor = base64.encodebytes(signature).replace(b"\n", b"\n")
        escaped = b"\n".join(b"- " + line if line.startswith(b"-") else line for line in data.split(b"\n"))
        return (b"-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\n" + escaped +
                b"-----BEGIN PGP SIGNATURE-----\n\n" + armor + b"=" +
                base64.b64encode((crc & 0xFFFFFF).to_bytes(3, "big")) + b"\n-----END PGP SIGNATURE-----\n")

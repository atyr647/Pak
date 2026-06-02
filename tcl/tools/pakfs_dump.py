import sys
import os, sys; sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
from pak.pakfs import pack
scenarios = [
    [("a.txt", b"hello")],
    [("sprites/player.sprite", b"\x01\x02\x03\x04\x05"), ("audio/jump.wav64", b"X"*17), ("empty", b"")],
    [("f%d" % i, bytes([i]*((i*7) % 40))) for i in range(5)],
]
out = bytearray()
for sc in scenarios:
    out += pack(sc)
    out += b"\n==SC==\n"
sys.stdout.buffer.write(out.hex().encode())

"""reaats_audio.py -- reads the sound files the analysis can take: WAV, AIFF (also AIFC with uncompressed or float samples) and FLAC.

    samples, rate = read_audio(path)      # samples: float64 array (frames, channels), values in -1..1

It needs numpy only. WAV comes from wavio; AIFF and FLAC are decoded here, so no other program or package is needed. FLAC is decoded
in plain Python: the result is exact (the same samples as any FLAC decoder), but it takes time for a long sound (see read_flac).
"""
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pyatsyn import wavio                                       # noqa: E402

WavError = wavio.WavError

FORMATS = "WAV, AIFF or FLAC"


def sniff(path):
    """'wav', 'aiff', 'flac' or None, from the first bytes of the file."""
    with open(path, "rb") as fh:
        head = fh.read(12)
    if head[:4] in (b"RIFF", b"RF64") and head[8:12] == b"WAVE":
        return "wav"
    if head[:4] == b"FORM" and head[8:12] in (b"AIFF", b"AIFC"):
        return "aiff"
    if head[:4] == b"fLaC":
        return "flac"
    return None


def read_audio(path, progress=None):
    """Reads a WAV, AIFF or FLAC file. `progress` (optional) is called with 0..1 while a FLAC file is decoded."""
    kind = sniff(path)
    if kind == "wav":
        return wavio.read_wav(path)
    if kind == "aiff":
        return read_aiff(path)
    if kind == "flac":
        return read_flac(path, progress)
    raise WavError("not a sound file the analysis can read (%s)" % FORMATS)


# ------------------------------------------------------------------------------------------------------------------ AIFF
def _extended_to_float(b):
    """An 80-bit IEEE extended number (the sample rate of an AIFF file), 10 bytes, big endian."""
    se, = struct.unpack(">H", b[:2])
    mant, = struct.unpack(">Q", b[2:])
    sign = -1.0 if se & 0x8000 else 1.0
    exp = se & 0x7FFF
    if exp == 0 and mant == 0:
        return 0.0
    return sign * mant * 2.0 ** (exp - 16383 - 63)


def read_aiff(path):
    with open(path, "rb") as fh:
        raw = fh.read()
    if raw[:4] != b"FORM" or raw[8:12] not in (b"AIFF", b"AIFC"):
        raise WavError("not an AIFF file")
    aifc = raw[8:12] == b"AIFC"
    pos, end = 12, len(raw)
    comm = ssnd = None
    while pos + 8 <= end:
        cid, size = raw[pos:pos + 4], struct.unpack(">I", raw[pos + 4:pos + 8])[0]
        body = raw[pos + 8:pos + 8 + size]
        if cid == b"COMM":
            comm = body
        elif cid == b"SSND":
            ssnd = body
        pos += 8 + size + (size & 1)                          # chunks are padded to an even size
    if comm is None or ssnd is None:
        raise WavError("the AIFF file has no COMM or SSND chunk")
    channels, frames, bits = struct.unpack(">hIh", comm[:8])
    rate = _extended_to_float(comm[8:18])
    kind = b"NONE"
    if aifc and len(comm) >= 22:
        kind = comm[18:22]
    if channels < 1 or rate <= 0 or bits not in (8, 16, 24, 32, 64):
        raise WavError("unusable AIFF header (%d channels, %d bit, %.0f Hz)" % (channels, bits, rate))
    offset, = struct.unpack(">I", ssnd[:4])
    data = ssnd[8 + offset:]
    width = bits // 8
    count = min(len(data) // (width * channels), frames if frames else len(data))
    data = data[:count * width * channels]
    little = kind in (b"sowt",)
    if kind in (b"fl32", b"FL32"):
        x = np.frombuffer(data, dtype=">f4").astype(np.float64)
    elif kind in (b"fl64", b"FL64"):
        x = np.frombuffer(data, dtype=">f8").astype(np.float64)
    elif kind in (b"NONE", b"none", b"sowt", b"twos", b"in24", b"in32"):
        if bits == 8:
            x = np.frombuffer(data, dtype=np.int8).astype(np.float64) / 128.0
        elif bits == 16:
            x = np.frombuffer(data, dtype="<i2" if little else ">i2").astype(np.float64) / 32768.0
        elif bits == 24:
            b = np.frombuffer(data, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
            v = (b[:, 2] << 16 | b[:, 1] << 8 | b[:, 0]) if little else (b[:, 0] << 16 | b[:, 1] << 8 | b[:, 2])
            x = np.where(v >= 1 << 23, v - (1 << 24), v).astype(np.float64) / 8388608.0
        elif bits == 32:
            x = np.frombuffer(data, dtype="<i4" if little else ">i4").astype(np.float64) / 2147483648.0
        else:
            raise WavError("AIFF with %d bit integer samples is not supported" % bits)
    else:
        raise WavError("this AIFC file is compressed (%s): only uncompressed AIFF is supported" % kind.decode("latin-1", "replace"))
    return x.reshape(-1, channels), int(round(rate))


# ------------------------------------------------------------------------------------------------------------------ FLAC
_BLOCK = {1: 192, 2: 576, 3: 1152, 4: 2304, 5: 4608, 8: 256, 9: 512, 10: 1024, 11: 2048, 12: 4096, 13: 8192, 14: 16384, 15: 32768}
_RATE = {1: 88200, 2: 176400, 3: 192000, 4: 8000, 5: 16000, 6: 22050, 7: 24000, 8: 32000, 9: 44100, 10: 48000, 11: 96000}
_BPS = {1: 8, 2: 12, 4: 16, 5: 20, 6: 24, 7: 32}


class _Bits:
    """Reads bits from the bytes of a frame (most significant bit first)."""
    __slots__ = ("data", "pos")

    def __init__(self, data):
        self.data = data + b"\0\0\0\0\0\0\0\0"                   # (padding, so that a read at the end does not need a check)
        self.pos = 0

    def read(self, n):
        if n == 0:
            return 0
        b0 = self.pos >> 3
        off = self.pos & 7
        nbytes = (off + n + 7) >> 3
        chunk = int.from_bytes(self.data[b0:b0 + nbytes], "big")
        self.pos += n
        return (chunk >> (nbytes * 8 - off - n)) & ((1 << n) - 1)

    def read_signed(self, n):
        v = self.read(n)
        return v - (1 << n) if n and v >= (1 << (n - 1)) else v

    def unary(self):
        """The number of zero bits before the next one bit (the one is consumed)."""
        pos, data, zeros = self.pos, self.data, 0
        while True:
            off = pos & 7
            byte = data[pos >> 3] & (0xFF >> off)
            if byte:
                hb = byte.bit_length() - 1
                zeros += (7 - hb) - off
                pos = (pos & ~7) + (7 - hb) + 1
                break
            zeros += 8 - off
            pos = (pos | 7) + 1
        self.pos = pos
        return zeros

    def align(self):
        self.pos = (self.pos + 7) & ~7


def _rice(bits, n, k):
    """n Rice-coded residual values with parameter k."""
    out = []
    data = bits.data
    pos = bits.pos
    append = out.append
    for _ in range(n):
        zeros = 0
        while True:                                              # the unary part
            off = pos & 7
            byte = data[pos >> 3] & (0xFF >> off)
            if byte:
                hb = byte.bit_length() - 1
                zeros += (7 - hb) - off
                pos = (pos & ~7) + (7 - hb) + 1
                break
            zeros += 8 - off
            pos = (pos | 7) + 1
        if k:
            b0 = pos >> 3
            off = pos & 7
            chunk = (data[b0] << 32) | (data[b0 + 1] << 24) | (data[b0 + 2] << 16) | (data[b0 + 3] << 8) | data[b0 + 4]
            r = (chunk >> (40 - off - k)) & ((1 << k) - 1)
            pos += k
            v = (zeros << k) | r
        else:
            v = zeros
        append((v >> 1) ^ -(v & 1))
    bits.pos = pos
    return out


def _residual(bits, block, order):
    method = bits.read(2)
    if method > 1:
        raise WavError("unusable FLAC residual coding")
    porder = bits.read(4)
    param_bits = 4 if method == 0 else 5
    escape = (1 << param_bits) - 1
    out = []
    parts = 1 << porder
    for i in range(parts):
        n = (block >> porder) - (order if i == 0 else 0)
        param = bits.read(param_bits)
        if param == escape:
            raw = bits.read(5)
            out.extend(bits.read_signed(raw) for _ in range(n)) if raw else out.extend([0] * n)
        else:
            out.extend(_rice(bits, n, param))
    return out


def _subframe(bits, block, bps):
    if bits.read(1) != 0:
        raise WavError("FLAC subframe header is wrong")
    typ = bits.read(6)
    wasted = 0
    if bits.read(1):
        wasted = bits.unary() + 1
    bps -= wasted
    if typ == 0:
        v = bits.read_signed(bps)
        x = [v] * block
    elif typ == 1:
        x = [bits.read_signed(bps) for _ in range(block)]
    elif 8 <= typ <= 12:
        order = typ - 8
        x = [bits.read_signed(bps) for _ in range(order)]
        res = _residual(bits, block, order)
        if order == 0:
            x = res
        else:
            coefs = ((1,), (2, -1), (3, -3, 1), (4, -6, 4, -1))[order - 1]
            for i, r in enumerate(res, order):
                p = 0
                for j, c in enumerate(coefs):
                    p += c * x[i - 1 - j]
                x.append(r + p)
    elif typ >= 32:
        order = typ - 31
        x = [bits.read_signed(bps) for _ in range(order)]
        precision = bits.read(4) + 1
        shift = bits.read_signed(5)
        coefs = [bits.read_signed(precision) for _ in range(order)]
        res = _residual(bits, block, order)
        if shift < 0:
            raise WavError("unusable FLAC prediction (negative shift)")
        for i, r in enumerate(res, order):
            p = 0
            for j in range(order):
                p += coefs[j] * x[i - 1 - j]
            x.append(r + (p >> shift))
    else:
        raise WavError("unusable FLAC subframe type %d" % typ)
    if wasted:
        x = [v << wasted for v in x]
    return x


def read_flac(path, progress=None):
    """Decodes a FLAC file completely. Speed of this pure Python decoder: about half a million samples per second on one core (measured
    on a real FLAC file), so a minute of stereo sound at 44.1 kHz takes about 10 seconds and nine minutes of stereo about 100 seconds.
    `progress` is called with 0..1 now and then."""
    with open(path, "rb") as fh:
        raw = fh.read()
    if raw[:4] != b"fLaC":
        raise WavError("not a FLAC file")
    pos = 4
    info = None
    max_frame = 0
    while True:                                                  # the metadata blocks
        if pos + 4 > len(raw):
            raise WavError("the FLAC file ends in its header")
        head = raw[pos]
        last, typ = head & 0x80, head & 0x7F
        size = int.from_bytes(raw[pos + 1:pos + 4], "big")
        if typ == 0:
            body = raw[pos + 4:pos + 4 + size]
            v = int.from_bytes(body[10:18], "big")
            info = {"rate": v >> 44, "channels": ((v >> 41) & 7) + 1, "bps": ((v >> 36) & 31) + 1, "total": v & ((1 << 36) - 1)}
            max_frame = int.from_bytes(body[7:10], "big")
        pos += 4 + size
        if last:
            break
    if info is None:
        raise WavError("the FLAC file has no STREAMINFO")
    channels, bps0, rate0 = info["channels"], info["bps"], info["rate"]
    out = [[] for _ in range(channels)]
    total_bytes = len(raw)
    last_report = 0.0
    while pos + 6 < len(raw):
        if raw[pos] != 0xFF or (raw[pos + 1] & 0xFC) != 0xF8:      # the frame sync (14 bits 11111111111110)
            raise WavError("FLAC frame sync lost at byte %d" % pos)
        b = _Bits(raw[pos:pos + (max_frame if max_frame else 1 << 21) + 64])      # (one frame is read from this piece)
        b.read(14)
        b.read(2)                                                 # reserved, blocking strategy
        bs_code, sr_code, ch_code, ss_code = b.read(4), b.read(4), b.read(4), b.read(3)
        b.read(1)
        first = b.read(8)                                         # the UTF-8 coded frame or sample number: skip it
        extra = 0
        if first & 0x80:
            mask = 0x40
            while first & mask:
                extra += 1
                mask >>= 1
        for _ in range(extra):
            b.read(8)
        block = _BLOCK.get(bs_code)
        if bs_code == 6:
            block = b.read(8) + 1
        elif bs_code == 7:
            block = b.read(16) + 1
        if block is None:
            raise WavError("unusable FLAC block size")
        if sr_code == 12:
            b.read(8)
        elif sr_code in (13, 14):
            b.read(16)
        b.read(8)                                                 # CRC-8
        bps = _BPS.get(ss_code, bps0) if ss_code else bps0
        if ch_code <= 7:
            chs = [_subframe(b, block, bps) for _ in range(ch_code + 1)]
        elif ch_code in (8, 9, 10):
            first_ch = _subframe(b, block, bps + (1 if ch_code == 9 else 0))
            second_ch = _subframe(b, block, bps + (0 if ch_code == 9 else 1))
            if ch_code == 8:                                      # left, side
                chs = [first_ch, [l - s for l, s in zip(first_ch, second_ch)]]
            elif ch_code == 9:                                    # side, right
                chs = [[s + r for s, r in zip(first_ch, second_ch)], second_ch]
            else:                                                 # mid, side
                left, right = [], []
                for m, s in zip(first_ch, second_ch):
                    m2 = (m << 1) | (s & 1)
                    left.append((m2 + s) >> 1)
                    right.append((m2 - s) >> 1)
                chs = [left, right]
        else:
            raise WavError("unusable FLAC channel assignment")
        for c in range(channels):
            out[c].extend(chs[c])
        b.align()
        b.read(16)                                                # CRC-16
        pos += b.pos >> 3
        if progress and pos / total_bytes - last_report >= 0.02:
            last_report = pos / total_bytes
            progress(last_report)
    scale = float(1 << (bps0 - 1))
    arr = np.array(out, dtype=np.float64).T / scale
    return arr, rate0


def describe(path):
    """(rate, channels, frames) from the header only, without decoding."""
    kind = sniff(path)
    if kind == "flac":
        with open(path, "rb") as fh:
            head = fh.read(42)
        v = int.from_bytes(head[18:26], "big")
        return v >> 44, ((v >> 41) & 7) + 1, v & ((1 << 36) - 1)
    x, rate = read_audio(path)
    return rate, x.shape[1], x.shape[0]

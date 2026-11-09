# -*- coding: utf-8 -*-
# wavio.py -- WAV reading and writing with numpy only (written for ReaATS, 9 November 2026).
# Replaces the `soundfile` package that pyatsyn used, so the analysis needs nothing but Python and numpy.
# Reads PCM (8, 16, 24, 32 bit) and float (32, 64 bit) WAV files, also the WAVE_FORMAT_EXTENSIBLE variant,
# any number of channels. Writes mono or multichannel 32-bit float WAV.

import struct
import numpy as np


class WavError(ValueError):
    pass


def read_wav(path):
    """Returns (samples, sample_rate); samples is a float64 array of shape (frames, channels), values in -1..1."""
    with open(path, "rb") as fh:
        raw = fh.read()
    if len(raw) < 12 or raw[:4] not in (b"RIFF", b"RF64") or raw[8:12] != b"WAVE":
        raise WavError("not a WAV file (only WAV is supported; export or render the sound as WAV first): " + str(path))
    pos = 12
    fmt = None
    data = None
    while pos + 8 <= len(raw):
        cid = raw[pos:pos + 4]
        size = struct.unpack("<I", raw[pos + 4:pos + 8])[0]
        body = pos + 8
        if cid == b"fmt ":
            fmt = raw[body:body + size]
        elif cid == b"data":
            if size == 0xFFFFFFFF or body + size > len(raw):       # streamed or truncated: take what is there
                size = len(raw) - body
            data = raw[body:body + size]
            break
        pos = body + size + (size & 1)
    if fmt is None or data is None or len(fmt) < 16:
        raise WavError("the WAV file has no fmt or data chunk: " + str(path))
    tag, channels, rate, _, _, bits = struct.unpack("<HHIIHH", fmt[:16])
    if tag == 0xFFFE and len(fmt) >= 26:                            # WAVE_FORMAT_EXTENSIBLE: the real tag is in the sub-format
        tag = struct.unpack("<H", fmt[24:26])[0]
    if channels < 1:
        raise WavError("the WAV file has no channels")
    width = bits // 8
    usable = len(data) - (len(data) % (width * channels))
    data = data[:usable]
    if tag == 1:                                                    # integer PCM
        if bits == 8:
            x = (np.frombuffer(data, dtype=np.uint8).astype(np.float64) - 128.0) / 128.0
        elif bits == 16:
            x = np.frombuffer(data, dtype="<i2").astype(np.float64) / 32768.0
        elif bits == 24:
            b = np.frombuffer(data, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
            v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
            v = np.where(v & 0x800000, v - 0x1000000, v)
            x = v.astype(np.float64) / 8388608.0
        elif bits == 32:
            x = np.frombuffer(data, dtype="<i4").astype(np.float64) / 2147483648.0
        else:
            raise WavError("unsupported PCM bit depth: %d" % bits)
    elif tag == 3:                                                  # IEEE float
        if bits == 32:
            x = np.frombuffer(data, dtype="<f4").astype(np.float64)
        elif bits == 64:
            x = np.frombuffer(data, dtype="<f8").astype(np.float64)
        else:
            raise WavError("unsupported float bit depth: %d" % bits)
    else:
        raise WavError("unsupported WAV format tag %d (only PCM and float)" % tag)
    return x.reshape(-1, channels), rate


def write_wav(path, samples, rate):
    """Writes a 32-bit float WAV. samples: 1-D (mono) or 2-D (frames, channels)."""
    a = np.asarray(samples, dtype="<f4")
    if a.ndim == 1:
        a = a.reshape(-1, 1)
    channels = a.shape[1]
    payload = a.tobytes()
    with open(path, "wb") as fh:
        fh.write(b"RIFF" + struct.pack("<I", 36 + len(payload)) + b"WAVE")
        fh.write(b"fmt " + struct.pack("<IHHIIHH", 16, 3, channels, int(rate), int(rate) * 4 * channels, 4 * channels, 32))
        fh.write(b"data" + struct.pack("<I", len(payload)) + payload)

"""Measure native DSP against independently bilinear-warped analog responses."""
from pathlib import Path
import ctypes as C
import json
import math
import re
import threading
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
lib = C.CDLL(str(ROOT / "build/tests/libSpatialShim.dylib"))
U = C.c_uint32


class Filter(C.Structure):
    _fields_ = [("type", U), ("enabled", U), ("frequency", C.c_double), ("gain", C.c_double), ("q", C.c_double)]


class Format(C.Structure):
    _fields_ = [("rate", C.c_double)] + [(name, U) for name in ("id", "flags", "packetBytes", "packetFrames", "frameBytes", "channels", "bits", "reserved")]


class Buffer(C.Structure):
    _fields_ = [("channels", U), ("bytes", U), ("data", C.c_void_p)]


class Buffers(C.Structure):
    _fields_ = [("count", U), ("buffers", Buffer * 2)]


class Timestamp(C.Structure):
    _fields_ = [("sample", C.c_double), ("host", C.c_uint64), ("scalar", C.c_double), ("word", C.c_uint64),
                ("smpte", C.c_byte * 24), ("flags", U), ("reserved", U)]


class Status(C.Structure):
    _fields_ = [("enabled", U), ("mixers", U), ("activeMixers", U), ("error", C.c_int32), ("sampleRate", C.c_double),
                ("generation", C.c_uint64), ("buffers", C.c_uint64), ("frames", C.c_uint64), ("minFrames", U), ("maxFrames", U)]


lib.SpatialEQSetConfiguration.argtypes = [C.POINTER(Filter), U, C.c_double, C.c_bool]
lib.SpatialEQSetConfiguration.restype = C.c_bool
lib.SpatialEQSetEnabled.argtypes = [C.c_bool]
lib.SpatialEQCreateForFormat.argtypes = [Format, U]
lib.SpatialEQCreateForFormat.restype = C.c_void_p
lib.SpatialEQDestroy.argtypes = [C.c_void_p]
lib.SpatialEQResetContext.argtypes = [C.c_void_p]
lib.SpatialEQProcess.argtypes = [C.c_void_p, C.POINTER(U), C.POINTER(Timestamp), U, C.POINTER(Buffers)]
lib.SpatialEQGetStatus.restype = Status

text = (ROOT / "Tests/Fixtures/Sony MDR-MV1 ParametricEq.txt").read_text()
preamp = float(re.search(r"Preamp: ([\d.-]+)", text)[1])
filters = [Filter({"PK": 0, "LSC": 1, "HSC": 2}[kind], 1, float(f), float(g), float(q))
           for kind, f, g, q in re.findall(r"ON (\w+) Fc ([\d.]+) Hz Gain ([\d.-]+) dB Q ([\d.]+)", text)]


def configure(values=filters, gain=preamp, enabled=True):
    native = (Filter * len(values))(*values)
    assert lib.SpatialEQSetConfiguration(native, len(values), gain, enabled)


def make(rate=48000, interleaved=False, channels=2, capacity=512):
    bytes_per_frame = (channels if interleaved else 1) * 4
    fmt = Format(rate, int.from_bytes(b"lpcm", "big"), 9 if interleaved else 41,
                 bytes_per_frame, 1, bytes_per_frame, channels, 32, 0)
    ctx = lib.SpatialEQCreateForFormat(fmt, capacity)
    assert ctx
    return ctx


def process(ctx, source, interleaved=False, start=0, silent=False, step=512):
    source = np.asarray(source, dtype=np.float32)
    result = np.empty_like(source)
    last_flags = 0
    for i in range(0, len(source), step):
        chunk = np.array(source[i:i + step], dtype=np.float32, copy=True, order="C")
        frames = len(chunk)
        data = Buffers()
        if interleaved:
            data.count = 1
            data.buffers[0] = Buffer(2, chunk.nbytes, chunk.ctypes.data)
        else:
            left, right = np.ascontiguousarray(chunk[:, 0]), np.ascontiguousarray(chunk[:, 1])
            data.count = 2
            data.buffers[0] = Buffer(1, left.nbytes, left.ctypes.data)
            data.buffers[1] = Buffer(1, right.nbytes, right.ctypes.data)
        flags = U(16 if silent else 0)
        time = Timestamp(sample=start + i, flags=1)
        lib.SpatialEQProcess(ctx, C.byref(flags), C.byref(time), frames, C.byref(data))
        if interleaved:
            result[i:i + frames] = chunk
        else:
            result[i:i + frames, 0], result[i:i + frames, 1] = left, right
        last_flags = flags.value
    assert np.isfinite(result).all()
    return result, last_flags


def warm(ctx, interleaved=False):
    process(ctx, np.zeros((4096, 2)), interleaved)
    lib.SpatialEQResetContext(ctx)


def reference(frequencies, rate, values=filters, gain=preamp):
    # Analog prototypes, evaluated using the bilinear transform/prewarping.
    # This does not reuse the production biquad coefficients or recurrence.
    result = np.full(frequencies.shape, 10 ** (gain / 20), dtype=np.complex128)
    for f in values:
        if not f.enabled:
            continue
        s = 1j * np.tan(np.pi * frequencies / rate) / math.tan(math.pi * f.frequency / rate)
        a = 10 ** (f.gain / 40)
        if f.type == 0:
            h = (s * s + a / f.q * s + 1) / (s * s + s / (a * f.q) + 1)
        elif f.type == 1:
            h = a * (s * s + math.sqrt(a) / f.q * s + a) / (a * s * s + math.sqrt(a) / f.q * s + 1)
        else:
            h = a * (a * s * s + math.sqrt(a) / f.q * s + 1) / (s * s + math.sqrt(a) / f.q * s + a)
        result *= h
    return 20 * np.log10(np.abs(result))


report = {"passed": False, "responseMaxErrorDB": {}}
for rate in (44100, 48000, 96000):
    for label, values, gain in (("sony", filters, preamp), ("peak", [filters[6]], 0),
                                ("lowShelf", [filters[0]], 0), ("highShelf", [filters[-1]], 0)):
        configure(values, gain)
        ctx = make(rate)
        try:
            warm(ctx)
            source = np.zeros((rate * 2, 2), dtype=np.float32)
            source[0, 0] = .05
            output, _ = process(ctx, source)
            assert np.max(np.abs(output[:, 1])) == 0, "Left impulse leaked into right filter history"
            fft = np.fft.rfft(output[:, 0].astype(np.float64)) / .05
            frequencies = np.fft.rfftfreq(len(source), 1 / rate)
            mask = (frequencies >= 20) & (frequencies <= 20000)
            measured = 20 * np.log10(np.abs(fft[mask]))
            maximum = float(np.max(np.abs(measured - reference(frequencies[mask], rate, values, gain))))
            assert maximum < .1, (rate, label, maximum)
            report["responseMaxErrorDB"][f"{rate}-{label}"] = maximum
        finally:
            lib.SpatialEQDestroy(ctx)
print("PASS: measured impulses match independent analog references at 44.1/48/96 kHz; max error",
      max(report["responseMaxErrorDB"].values()), "dB", flush=True)

# The same stereo samples in the two layouts must produce the same output.
configure()
random = np.random.default_rng(123).normal(0, .02, (4096, 2)).astype(np.float32)
outputs = []
for interleaved in (False, True):
    ctx = make(interleaved=interleaved)
    try:
        warm(ctx, interleaved)
        first, _ = process(ctx, random, interleaved)
        repeated, _ = process(ctx, np.zeros((512, 2)), interleaved, start=3584)
        assert np.array_equal(repeated, first[-512:]), "Same timestamp was filtered twice"
        lib.SpatialEQResetContext(ctx)
        second, _ = process(ctx, random, interleaved)
        assert np.array_equal(first, second), "Explicit reset retained history"
        outputs.append(first)
    finally:
        lib.SpatialEQDestroy(ctx)
assert np.array_equal(*outputs)

# Silence is a source hint, not permission to discard the IIR's audible tail.
configure([Filter(0, 1, 1000, 12, 2)], 0)
ctx = make()
try:
    warm(ctx)
    impulse = np.zeros((512, 2), np.float32); impulse[0, 0] = .1
    process(ctx, impulse)
    tail, flags = process(ctx, np.ones((512, 2)), start=512, silent=True)
    assert np.max(np.abs(tail[:, 0])) > 1e-8 and not flags & 16
    settled, flags = process(ctx, np.ones((48000, 2)), start=1024, silent=True)
    assert np.max(np.abs(settled[-512:])) == 0 and flags & 16
finally:
    lib.SpatialEQDestroy(ctx)

# Configuration failures are atomic; unsupported rates/formats bypass the whole EQ.
configure([Filter(0, 1, 30000, 6, 1)], 0)
ctx = make()
try:
    output, _ = process(ctx, random[:512])
    assert np.array_equal(output, random[:512]) and lib.SpatialEQGetStatus().error == 2
finally:
    lib.SpatialEQDestroy(ctx)
configure()
ctx = make(channels=6)
try:
    output, _ = process(ctx, random[:512])
    assert np.array_equal(output, random[:512]) and lib.SpatialEQGetStatus().error == 1
finally:
    lib.SpatialEQDestroy(ctx)
assert not lib.SpatialEQSetConfiguration((Filter * 1)(Filter(0, 1, 1000, 6, 0)), 1, 0, True)
assert not lib.SpatialEQSetConfiguration(None, 33, 0, True)

# A gain-only change gives an exact, measurable bound on the 20 ms crossfade.
configure([], -6.020599913279624)
ctx = make()
try:
    constant = np.full((2048, 2), .25, np.float32)
    faded, _ = process(ctx, constant)
    assert abs(float(faded[-1, 0]) - .125) < 1e-7
    assert np.max(np.abs(np.diff(faded[:, 0]))) < .00014
    lib.SpatialEQSetEnabled(False)
    bypass, _ = process(ctx, constant, start=2048)
    assert np.array_equal(bypass[-512:], constant[-512:])
    for i in range(200):
        configure([], -3 if i % 2 else -12)
        process(ctx, constant[:1], start=4096 + i)
    configure([], -6.020599913279624)
    last, _ = process(ctx, constant, start=4296)
    assert abs(float(last[-1, 0]) - .125) < 1e-7
finally:
    lib.SpatialEQDestroy(ctx)

# Exercise publication and context creation/destruction while another thread renders.
configure()
ctx = make()
failure = []
def writer():
    try:
        for i in range(300):
            configure(filters, -3.12 if i % 2 else -6)
            temporary = make()
            lib.SpatialEQDestroy(temporary)
    except BaseException as error:
        failure.append(repr(error))
thread = threading.Thread(target=writer)
thread.start()
try:
    for i in range(300):
        process(ctx, random[:512], start=i * 512)
    thread.join(timeout=10)
    assert not thread.is_alive() and not failure
finally:
    lib.SpatialEQDestroy(ctx)
assert lib.SpatialEQGetStatus().mixers == 0
report["passed"] = True
destination = ROOT / "Tests/Artifacts/equalizer"
destination.mkdir(parents=True, exist_ok=True)
(destination / "dsp-result.json").write_text(json.dumps(report, indent=2))
print("PASS: layouts, independent channel state, cached renders, reset, silence tails, whole-EQ bypass, 20 ms transitions, rapid updates and concurrent lifecycle/publication")

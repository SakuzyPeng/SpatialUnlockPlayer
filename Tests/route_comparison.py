"""Capture native-vs-compatible routes, preserving system preferences.

Requires NumPy/SciPy. PCM files are two-channel little-endian Float32. The probe
only observes its own playback; no microphone or system loopback is recorded.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import struct
import subprocess
from datetime import datetime, timezone

import numpy as np
from scipy import signal

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'Tests/Artifacts/route-comparison'
PROBE = ROOT / 'build/tests/route-probe/route-probe'
RATE = 48000


def generate():
    """Six independent, band-limited, seeded signals with a silent lead/tail."""
    ART.mkdir(parents=True, exist_ok=True)
    path = ART / 'broadband-5.1.wav'
    rng = np.random.default_rng(20261024)
    x = np.zeros((RATE * 8, 6))
    length = RATE * 6
    envelope = np.ones(length)
    fade = np.sin(np.linspace(0, np.pi / 2, 2400)) ** 2
    envelope[:2400] = fade
    envelope[-2400:] = fade[::-1]
    for c in range(6):
        band = (25, 120) if c == 3 else (80, 18000)
        filt = signal.butter(3, band, btype='bandpass', fs=RATE, output='sos')
        y = signal.sosfilt(filt, rng.standard_normal(length))
        y *= .025 / np.sqrt(np.mean(y * y))
        x[RATE:RATE + length, c] = y * envelope
    pcm = np.round(np.clip(x, -1, 1) * 32767).astype('<i2').tobytes()
    guid = struct.pack('<IHH8s', 1, 0, 0x10, b'\x80\x00\x00\xaa\x00\x38\x9b\x71')
    fmt = struct.pack('<HHIIHHHHI', 0xfffe, 6, RATE, RATE * 12, 12, 16, 22, 16, 0x3f) + guid
    path.write_bytes(b'RIFF' + struct.pack('<I', 4 + 8 + len(fmt) + 8 + len(pcm)) + b'WAVE' +
                     b'fmt ' + struct.pack('<I', len(fmt)) + fmt + b'data' + struct.pack('<I', len(pcm)) + pcm)
    return path


def capture(label, uid, route, media=None, seek=0, duration=8, yaw=0, hrtf=None,
            trace_units=False, headroom_db=None, production=False):
    ART.mkdir(parents=True, exist_ok=True)
    media = Path(media) if media else generate()
    prefix = ART / label
    env = dict(os.environ)
    env.pop('DYLD_INSERT_LIBRARIES', None)
    env.pop('ROUTE_PROBE_HRTF', None)
    env.pop('ROUTE_PROBE_TRACE_UNITS', None)
    env.pop('ROUTE_PROBE_HEADROOM_DB', None)
    env.pop('ROUTE_PROBE_PRODUCTION', None)
    env.pop('ROUTE_PROBE_PRODUCTION_HEADROOM_DB', None)
    if hrtf is not None:
        env['ROUTE_PROBE_HRTF'] = str(hrtf)
    if trace_units or (headroom_db is not None and not production):
        env['ROUTE_PROBE_TRACE_UNITS'] = '1'
    if production: env['ROUTE_PROBE_PRODUCTION'] = '1'
    if headroom_db is not None:
        if not np.isfinite(headroom_db) or not 0 <= headroom_db <= 20:
            raise ValueError('Headroom must be between 0 and 20 dB')
        env['ROUTE_PROBE_PRODUCTION_HEADROOM_DB' if production else 'ROUTE_PROBE_HEADROOM_DB'] = str(headroom_db)
    with prefix.with_suffix('.log').open('w') as log:
        subprocess.run([str(PROBE), str(media), uid, route, str(seek), str(duration), str(yaw), str(prefix)],
                       env=env, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=duration + 25, check=True)
    report = json.loads(prefix.with_suffix('.json').read_text())
    with media.open('rb') as source:
        report['sourceSHA256'] = hashlib.file_digest(source, 'sha256').hexdigest()
    report['capturedAtUTC'] = datetime.now(timezone.utc).isoformat()
    report['pcmEncoding'] = 'little-endian float32, interleaved stereo'
    prefix.with_suffix('.json').write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(json.dumps(compact(report), ensure_ascii=False), flush=True)
    return report


def compact(report):
    stages = []
    for r in report['records']:
        stages.append({k: r[k] for k in ('kind', 'frames', 'sampleRate', 'channels', 'errors', 'gaps',
                                      'unsupported', 'overflow', 'properties', 'quaternion', 'hrtfOverrideError')})
    return {**{k: report[k] for k in ('route', 'hrtfOverride', 'yaw', 'queueSpatial', 'queueLayout',
                                     'overriddenQueries', 'poseErrors')}, 'device': report['device']['name'], 'stages': stages}


def read(label, stage):
    report = json.loads((ART / (label + '.json')).read_text())
    if not report['ready'] or not report['sought'] or report['error'] or report['poseErrors']:
        raise ValueError(f'{label}: unsuccessful playback/pose capture')
    if report['position'] < report['seek'] + report['duration'] - .1:
        raise ValueError(f'{label}: incomplete playback')
    candidates = [r for r in report['records'] if r['kind'] == stage and r['frames'] > RATE]
    if len(candidates) != 1:
        raise ValueError(f'{label}: expected one active {stage}, found {len(candidates)}')
    r = candidates[0]
    if not r['saved']:
        raise ValueError(f'{label}: PCM write failed')
    if stage == 'hal-output' and r['deviceID'] != report['device']['id']:
        raise ValueError(f'{label}: HAL route changed')
    for key in ('errors', 'unsupported', 'overflow', 'formatError', 'notifyError', 'gaps'):
        if r[key]:
            raise ValueError(f'{label}: {key}={r[key]}')
    if r['sampleRate'] != RATE or r['channels'] != 2:
        raise ValueError(f'{label}: unexpected format')
    path = Path(r['pcm'])
    data = np.fromfile(path if path.is_absolute() else ROOT / path, dtype='<f4').reshape(-1, 2)
    if len(data) != r['frames']:
        raise ValueError(f'{label}: truncated PCM file')
    if not np.all(np.isfinite(data)):
        raise ValueError(f'{label}: nonfinite samples')
    return report, r, data


def compare(a_label, b_label, stage='spatial-postrender', b_stage=None):
    a_report, a_rec, a = read(a_label, stage)
    b_report, b_rec, b = read(b_label, b_stage or stage)
    if a_report['sourceSHA256'] != b_report['sourceSHA256']:
        raise ValueError('Different input media')
    if a_report['seek'] != b_report['seek']:
        raise ValueError('Different media positions')
    # One common time shift for both ears; never fit independent ear delays.
    ac = a[:, 0].astype(np.float64)
    bc = b[:, 0].astype(np.float64)
    corr = signal.correlate(bc, ac, mode='full', method='fft')
    lags = signal.correlation_lags(len(bc), len(ac))
    valid = np.abs(lags) < RATE * 2
    lag = int(lags[valid][np.argmax(corr[valid])])
    a_start, b_start = max(0, -lag), max(0, lag)
    count = min(len(a) - a_start, len(b) - b_start)
    aa = a[a_start:a_start + count]
    bb = b[b_start:b_start + count]
    # Exclude start-up and the last half-second, retain the waveform (no EQ,
    # time-warp, per-channel gains, or frequency-domain correction in the null).
    lo, hi = RATE, count - RATE // 2
    if hi - lo < RATE * 2:
        raise ValueError('Insufficient common capture')
    af, bf = aa[lo:hi], bb[lo:hi]
    ad, bd = af.astype(np.float64), bf.astype(np.float64)
    gain = float(np.sum(ad * bd) / np.sum(ad * ad))
    energy = float(np.sum(bd * bd))
    residual = bd - gain * ad
    def rel_db(error):
        power = float(np.sum(error * error))
        return 10 * np.log10(power / energy) if power > 0 else None
    metrics = {
        'a': a_label, 'b': b_label, 'stage': stage, 'bStage': b_stage or stage,
        'lagSamples': lag, 'comparedFrames': len(af), 'durationSeconds': len(af) / RATE,
        'bitIdentical': bool(np.array_equal(af.view(np.uint32), bf.view(np.uint32))),
        'exactSampleFraction': float(np.mean(af == bf)),
        'rawMaxAbsoluteError': float(np.max(np.abs(bd - ad))), 'rawResidualDB': rel_db(bd - ad),
        'bestCommonGain': gain, 'gainDB': float(20 * np.log10(abs(gain))),
        'gainAdjustedResidualDB': rel_db(residual), 'gainAdjustedMaxError': float(np.max(np.abs(residual))),
        'earCorrelation': [float(np.corrcoef(ad[:, c], bd[:, c])[0, 1]) for c in range(2)],
        'hrtfA': a_rec['properties'].get('personalizedActive'),
        'hrtfB': b_rec['properties'].get('personalizedActive'),
        'gapsA': a_rec['gaps'], 'gapsB': b_rec['gaps'],
    }
    # Windowed nulls expose motion, late setting changes, and clock drift.
    windows = []
    for start in range(0, len(ad) - RATE + 1, RATE):
        x, y = ad[start:start + RATE], bd[start:start + RATE]
        g = float(np.sum(x * y) / np.sum(x * x))
        e = float(np.sum((y - g * x) ** 2))
        windows.append({'second': start / RATE, 'gain': g,
                        'residualDB': float(10 * np.log10(e / np.sum(y * y))) if e else None})
    metrics['windows'] = windows
    # Also report a fixed later window, without hiding the full-window
    # result, to separate observed start-up gain ramps from steady output.
    if len(ad) >= RATE * 5:
        x, y = ad[RATE * 3:RATE * 5], bd[RATE * 3:RATE * 5]
        g = float(np.sum(x * y) / np.sum(x * x))
        e = float(np.sum((y - x) ** 2))
        e_fit = float(np.sum((y - g * x) ** 2))
        metrics['lateWindow'] = {
            'startFrameA': a_start + lo + RATE * 3, 'frames': RATE * 2,
            'bitIdentical': bool(np.array_equal(x, y)), 'gain': g,
            'rawMaxAbsoluteError': float(np.max(np.abs(y - x))),
            'rawResidualDB': float(10 * np.log10(e / np.sum(y * y))) if e else None,
            'gainAdjustedResidualDB': float(10 * np.log10(e_fit / np.sum(y * y))) if e_fit else None,
        }
    return metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('generate')
    cap = commands.add_parser('capture')
    cap.add_argument('label'); cap.add_argument('uid'); cap.add_argument('route', choices=['native', 'shim', 'off'])
    cap.add_argument('--media'); cap.add_argument('--seek', type=float, default=0)
    cap.add_argument('--duration', type=float, default=8); cap.add_argument('--yaw', type=float, default=0)
    cap.add_argument('--hrtf', type=int, choices=[0, 1, 2])
    cap.add_argument('--trace-units', action='store_true', help='Observe intermediate Apple Audio Units')
    cap.add_argument('--headroom-db', type=float,
                     help='Test-only paired pre/post gains around the observed dynamics chain; enables unit tracing')
    cap.add_argument('--production', action='store_true', help='Exercise the shipping topology-based configuration module')
    comp = commands.add_parser('compare')
    comp.add_argument('a'); comp.add_argument('b'); comp.add_argument('--stage', default='spatial-postrender')
    comp.add_argument('--b-stage'); comp.add_argument('--output')
    args = parser.parse_args()
    if args.command == 'generate': print(generate())
    elif args.command == 'capture':
        capture(args.label, args.uid, args.route, args.media, args.seek, args.duration, args.yaw, args.hrtf,
                args.trace_units, args.headroom_db, args.production)
    else:
        result = compare(args.a, args.b, args.stage, args.b_stage)
        text = json.dumps(result, indent=2, ensure_ascii=False)
        if args.output: Path(args.output).write_text(text)
        print(text)


if __name__ == '__main__':
    main()

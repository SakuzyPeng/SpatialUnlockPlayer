"""Validate Darwin USB ISO audio and compare it with simultaneous HAL PCM.

Raw nulls use one common integer delay for both ears, with no gain correction,
resampling, EQ, or time warp. Common-gain fits are diagnostics only.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess

import numpy as np
from scipy import signal

import route_comparison as rc
from usb_audio_comparison import ART, WS, device


def pcm_formats(hex_descriptor):
    """Read UAC2 Type I PCM alternate settings from a cached USB descriptor."""
    data = bytes.fromhex(hex_descriptor)
    result, current = [], None
    offset = 0
    while offset < len(data):
        size = data[offset]
        if size < 2 or offset + size > len(data):
            raise ValueError('Truncated USB descriptor')
        d = data[offset:offset + size]
        if d[1] == 4:
            current = {'interface': d[2], 'alternate': d[3]} if (
                size >= 9 and d[5:8] == bytes([1, 2, 0x20])) else None
        elif current is not None and d[1] == 0x24 and size >= 3:
            if d[2] == 1 and size >= 16:
                current['channels'] = d[10]
                current['pcm'] = int.from_bytes(d[6:10], 'little') == 1
            elif d[2] == 2 and size >= 6 and d[3] == 1:
                current['containerBytes'] = d[4]
                current['bits'] = d[5]
        elif (current is not None and d[1] == 5 and size >= 7 and
              not d[2] & 0x80 and d[3] & 3 == 1 and current.get('pcm')):
            result.append({**current, 'endpoint': d[2], 'interval': d[6]})
        offset += size
    return result


def decode_pcm(data, container_bytes, bits, channels):
    if container_bytes not in (2, 3, 4) or not 1 <= bits <= container_bytes * 8:
        raise ValueError('Unsupported signed little-endian PCM format')
    if len(data) % (container_bytes * channels):
        raise ValueError('Partial USB audio frame')
    if container_bytes == 3:
        b = np.frombuffer(data, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        values = (b[:, 0] | b[:, 1] << 8 | b[:, 2] << 16)
        values = (values ^ 0x800000) - 0x800000
    else:
        values = np.frombuffer(data, dtype=f'<i{container_bytes}').astype(np.int64)
    padding = container_bytes * 8 - bits
    if padding and np.any(values & ((1 << padding) - 1)):
        raise ValueError('Nonzero unused USB PCM bits')
    samples = values >> padding
    return samples.reshape(-1, channels), samples.reshape(-1, channels) / 2 ** (bits - 1)


def read_usb(label):
    meta = json.loads((ART / (label + '.usb.json')).read_text())
    target = device(meta['configured'], meta['uid'])
    usb = meta['usb']
    log = (ART / (label + '.dumpcap.log')).read_text()
    if not re.search(r'received/dropped.*?: \d+/0 \(', log):
        raise ValueError('USB capture drops are not confirmed zero')
    after_usb = next(d for d in meta['after']['usb']
                     if d['USB Product Name'] == usb['USB Product Name'])
    if any(after_usb[k] != usb[k] for k in ('locationID', 'USB Address', 'idVendor', 'idProduct')):
        raise ValueError('USB device identity changed during playback')
    if device(meta['after'], meta['uid'])['streams'][0]['physical'] != target['streams'][0]['physical']:
        raise ValueError('Physical audio format changed during playback')
    if usb['descriptorError']:
        raise ValueError('USB format descriptor unavailable')
    formats = pcm_formats(usb['configurationDescriptorHex'])
    physical = target['streams'][0]['physical']['format']
    if physical['flags'] & 1:  # AirPods virtual transport exposes Float32.
        if len(formats) != 1:
            raise ValueError('Ambiguous physical USB format')
        fmt = formats[0]
    else:
        candidates = [f for f in formats if f['bits'] == physical['bits']]
        if len(candidates) != 1:
            raise ValueError('Ambiguous physical USB format')
        fmt = candidates[0]
    if fmt['channels'] != 2 or physical['sampleRate'] != rc.RATE:
        raise ValueError('Expected 48 kHz stereo USB audio')
    fields = ['frame.number', 'frame.time_epoch', 'usb.darwin.io_status',
        'usb.darwin.io_len', 'usb.darwin.io_frame_count', 'usb.darwin.iso.status',
        'usb.darwin.iso.frame_number', 'usb.iso.iso_len', 'usb.iso.data',
        'usb.darwin_device_speed']
    command = [str(WS / 'tshark'), '-n', '-r', meta['pcap'], '-T', 'fields']
    for field in fields:
        command.extend(['-e', field])
    command.extend(['-Y',
        f'usb.darwin.location_id == {usb["locationID"]} && '
        f'usb.darwin.device_address == {usb["USB Address"]} && '
        f'usb.darwin.endpoint_address == {fmt["endpoint"]} && '
        'usb.darwin.endpoint_type == 1 && usb.darwin.request_type == 1'])
    text = subprocess.check_output(command, text=True)
    good, failed = [], []
    for line in text.splitlines():
        (packet, timestamp, status, length, count, statuses, frames,
            lengths, payloads, speed) = line.split('\t')
        starts = [int(v, 0) for v in frames.split(',') if v]
        if int(status, 0):
            failed.append(starts[0] if starts else None)
            continue
        statuses = [int(v, 0) for v in statuses.split(',') if v]
        lengths = [int(v, 0) for v in lengths.split(',') if v]
        count = int(count)
        if not starts or len(starts) != count or len(statuses) != count or len(lengths) != count:
            raise ValueError('Missing ISO frame metadata')
        if any(statuses):
            raise ValueError('Unsuccessful ISO frame inside a successful transfer')
        payload = b''.join(bytes.fromhex(v.replace(':', ''))
                           for v in payloads.split(',') if v)
        if len(payload) != int(length) or len(payload) != sum(lengths):
            raise ValueError('Truncated ISO payload')
        frame_bytes = fmt['channels'] * fmt['containerBytes']
        if any(n % frame_bytes for n in lengths):
            raise ValueError('Partial audio frame in ISO payload')
        # Wireshark labels high-speed microframes as start+i. Use the first
        # frame number and microframe count, rather than flattening those labels.
        per_ms = 8 if int(speed) >= 2 else 1
        if count % per_ms:
            raise ValueError('Unsupported fractional USB frame interval')
        good.append({'start': starts[0], 'span': count // per_ms,
                     'packet': int(packet), 'time': float(timestamp),
                     'payload': payload})
    if not good:
        raise ValueError('No successful USB audio transfers')
    good.sort(key=lambda r: r['start'])
    for a, b in zip(good, good[1:]):
        if b['start'] != a['start'] + a['span']:
            raise ValueError('Missing or repeated USB audio transfer')
    if any(v is None or good[0]['start'] <= v <= good[-1]['start'] for v in failed):
        raise ValueError('Unsuccessful transfer within the compared stream')
    payload = b''.join(r['payload'] for r in good)
    integers, pcm = decode_pcm(payload, fmt['containerBytes'], fmt['bits'], fmt['channels'])
    nominal_frames = sum(r['span'] for r in good) * rc.RATE / 1000
    if abs(len(pcm) - nominal_frames) > max(10, nominal_frames * .001):
        raise ValueError('USB payload duration disagrees with the frame timeline')
    report = json.loads((ART / (label + '.json')).read_text())
    if len(pcm) < (report['duration'] - .1) * rc.RATE:
        raise ValueError('Incomplete USB playback capture')
    raw_path = ART / (label + '.usb.raw')
    raw_path.write_bytes(payload)
    info = {'label': label, 'format': fmt, 'sampleRate': physical['sampleRate'],
        'frames': len(pcm), 'payloadBytes': len(payload), 'successfulTransfers': len(good),
        'usbFrameGaps': 0, 'captureDrops': 0,
        'transferSizeCounts': dict(Counter(len(r['payload']) for r in good)),
        'raw': str(raw_path), 'sha256': hashlib.sha256(payload).hexdigest()}
    (ART / (label + '.usb-pcm.json')).write_text(json.dumps(info, indent=2))
    return info, integers, pcm


def relative_db(error, reference):
    e = float(np.sum(error * error)); r = float(np.sum(reference * reference))
    return float(10 * np.log10(e / r)) if e and r else None


def compare_arrays(a, b):
    if (a.ndim != 2 or b.ndim != 2 or a.shape[1] != 2 or b.shape[1] != 2 or
            not np.all(np.isfinite(a)) or not np.all(np.isfinite(b))):
        raise ValueError('Expected finite stereo samples')
    corr = signal.correlate(b[:, 0], a[:, 0], mode='full', method='fft')
    lags = signal.correlation_lags(len(b), len(a))
    selected = np.abs(lags) < rc.RATE * 3
    lag = int(lags[selected][np.argmax(corr[selected])])
    a_start, b_start = max(0, -lag), max(0, lag)
    count = min(len(a) - a_start, len(b) - b_start)
    lo, hi = rc.RATE, count - rc.RATE // 2
    if hi - lo < rc.RATE * 2:
        raise ValueError('Insufficient common audio')
    x = a[a_start + lo:a_start + hi].astype(np.float64)
    y = b[b_start + lo:b_start + hi].astype(np.float64)
    if not np.sum(x * x) or not np.sum(y * y):
        raise ValueError('Cannot align/compare silence alone')
    gain = float(np.sum(x * y) / np.sum(x * x))
    error = y - x; fitted = y - gain * x
    result = {'lagSamples': lag, 'startFrameA': a_start + lo,
        'startFrameB': b_start + lo, 'comparedFrames': len(x),
        'exactSamples': bool(np.array_equal(x.view(np.uint64), y.view(np.uint64))),
        'exactSampleFraction': float(np.mean(x.view(np.uint64) == y.view(np.uint64))),
        'rawMaxAbsoluteError': float(np.max(np.abs(error))),
        'rawResidualDB': relative_db(error, y),
        'bestCommonGain': gain, 'gainDB': float(20 * np.log10(abs(gain))),
        'gainAdjustedMaxError': float(np.max(np.abs(fitted))),
        'gainAdjustedResidualDB': relative_db(fitted, y), 'windows': []}
    for start in range(0, len(x) - rc.RATE + 1, rc.RATE):
        xx, yy = x[start:start + rc.RATE], y[start:start + rc.RATE]
        g = float(np.sum(xx * yy) / np.sum(xx * xx)) if np.any(xx) else None
        result['windows'].append({'second': start / rc.RATE, 'gain': g,
            'rawMaxError': float(np.max(np.abs(yy - xx))),
            'gainAdjustedResidualDB': relative_db(yy - g * xx, yy) if g is not None else None})
    return result, x, y


def analyze(labels, pairs):
    rc.ART = ART
    result = {'captures': {}, 'comparisons': {}}
    data = {}
    for label in labels:
        info, _, pcm = read_usb(label)
        report, record, hal = rc.read(label, 'hal-output')
        spatial = rc.read(label, 'spatial-postrender')[2] if report['route'] != 'off' else None
        metric, h, u = compare_arrays(hal, pcm)
        lsb = 2 ** -(info['format']['bits'] - 1)
        metric['rawMaxErrorLSB'] = metric['rawMaxAbsoluteError'] / lsb
        # Known transformations are diagnostics, not fitted equality claims.
        metric['knownGainQuantization'] = {}
        for name, gain, rounding in [('unity-nearest', 1, np.rint),
                ('minus12dB-truncate', 10 ** (-12 / 20), np.trunc)]:
            predicted = rounding(h * gain / lsb)
            actual = np.rint(u / lsb)
            error = actual - predicted
            metric['knownGainQuantization'][name] = {
                'maxErrorLSB': float(np.max(np.abs(error))),
                'exactSampleFraction': float(np.mean(error == 0))}
        result['captures'][label] = {**info, 'halToUSB': metric,
            'actualHRTF': report['productionRender']['actualHRTF'],
            'headroom': report['productionRender']['preGain'],
            'sourceSHA256': report['sourceSHA256']}
        data[label] = {'usb': pcm, 'hal': hal, 'spatial': spatial, 'report': report}
    for key, left, right in pairs:
        a, b = data[left], data[right]
        if a['report']['sourceSHA256'] != b['report']['sourceSHA256']:
            raise ValueError('Different input media')
        if a['report']['seek'] != b['report']['seek']:
            raise ValueError('Different media positions')
        result['comparisons'][key] = {stage: compare_arrays(a[stage], b[stage])[0]
            for stage in ('spatial', 'hal', 'usb') if a[stage] is not None and b[stage] is not None}
        result['comparisons'][key]['a'] = left
        result['comparisons'][key]['b'] = right
    (ART / 'summary.json').write_text(json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('labels', nargs='*')
    parser.add_argument('--completed-suite', action='store_true',
                        help='Reanalyze the saved 16-capture, 9-comparison experiment')
    parser.add_argument('--pair', nargs=3, action='append', default=[], metavar=('NAME', 'A', 'B'))
    args = parser.parse_args()
    if args.completed_suite:
        if args.labels or args.pair:
            parser.error('--completed-suite supplies its own labels and pairs')
        cases = ['hot-0', 'hot-20', 'hot-7p3', 'atmos-20', 'apac16-20', 'eq-yaw45']
        labels = [f'aligned-{c}-{d}' for c in cases for d in ('airpods', 'fiio')]
        labels += ['original-volume-airpods', 'original-format-fiio', 'off-stereo-airpods', 'off-stereo-fiio']
        pairs = [(c, f'aligned-{c}-airpods', f'aligned-{c}-fiio') for c in cases]
        pairs += [('airpods-volume', 'original-volume-airpods', 'aligned-hot-20-airpods'),
                  ('fiio-bit-depth', 'original-format-fiio', 'aligned-hot-20-fiio'),
                  ('off-stereo', 'off-stereo-airpods', 'off-stereo-fiio')]
    else:
        if not args.labels:
            parser.error('Supply capture labels or --completed-suite')
        labels, pairs = args.labels, args.pair
    result = analyze(labels, pairs)
    for label, r in result['captures'].items():
        m = r['halToUSB']
        print(label, f'{r["format"]["bits"]}-bit', f'HAL->USB {m["gainDB"]:.6f} dB',
              f'gain-adjusted residual {m["gainAdjustedResidualDB"]:.2f} dB')
    for label, r in result['comparisons'].items():
        print(label, {s: {'exact': r[s]['exactSamples'], 'gainDB': r[s]['gainDB'],
                         'residualDB': r[s]['gainAdjustedResidualDB']} for s in ('spatial', 'hal', 'usb') if s in r})


if __name__ == '__main__':
    main()

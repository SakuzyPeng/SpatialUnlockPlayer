"""Synchronized research-only AVPlayer/HAL and Darwin USB audio capture.

Uses the existing route probe plus Wireshark dumpcap/tshark. Device settings
changed for a capture are restored in finally; no production PCM capture code.
"""
import argparse
import contextlib
import io
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import time

import route_comparison as rc

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'Tests/Artifacts/usb-comparison'
WS = Path('/Applications/Wireshark.app/Contents/MacOS')
METADATA = ROOT / 'build/tests/route-probe/usb-audio-metadata'


def metadata(*args):
    return json.loads(subprocess.check_output([str(METADATA), *map(str, args)], text=True))


def device(meta, uid):
    return next(d for d in meta['audio'] if d['uid'] == uid)


def capture(label, uid, route, media, usb_product, headroom=20, hrtf=0,
            yaw=0, seek=0, duration=8, volume=None, bits=None, eq=False,
            interface='XHC2'):
    if not re.fullmatch(r'[a-zA-Z0-9_-]+', label):
        raise ValueError('Use a simple unique capture label')
    if not math.isfinite(duration) or not 0 < duration <= 18 or not math.isfinite(seek) or seek < 0:
        raise ValueError('Capture duration must be 0–18 seconds and seek must be nonnegative')
    if headroom is not None and (not math.isfinite(headroom) or not 0 <= headroom <= 20):
        raise ValueError('Headroom must be 0–20 dB')
    if not math.isfinite(yaw) or hrtf not in (0, 1):
        raise ValueError('Use a finite yaw and explicit generic/personalized HRTF')
    if bits is not None and bits not in (16, 24, 32):
        raise ValueError('Unsupported PCM bit depth')
    ART.mkdir(parents=True, exist_ok=True)
    prefix = ART / label
    if prefix.with_suffix('.pcapng').exists():
        raise FileExistsError(f'{label}: capture already exists')
    original = metadata()
    target = device(original, uid)
    usb = next(d for d in original['usb'] if d['USB Product Name'] == usb_product)
    original_bits = target['streams'][0]['physical']['format']['bits']
    original_volume = next((v['scalar'] for v in target['volumes']
                            if v['channel'] == 0 and not v['scalarError']), None)
    if volume is not None and original_volume is None:
        raise ValueError('Device has no readable master volume to restore')
    volume_changed = bits_changed = False
    previous_eq = os.environ.get('ROUTE_PROBE_EQ')
    try:
        if bits is not None and bits != original_bits:
            bits_changed = True
            metadata('--bits', uid, bits)
        if volume is not None:
            volume_changed = True
            metadata('--volume', uid, volume)
        configured = metadata()
        configured_device = device(configured, uid)
        if bits is not None and configured_device['streams'][0]['physical']['format']['bits'] != bits:
            raise ValueError('Requested physical bit depth did not apply')
        if volume is not None:
            master = next(v for v in configured_device['volumes'] if v['channel'] == 0)
            if master['scalarError'] or abs(master['scalar'] - volume) > 1e-5:
                raise ValueError('Requested master volume did not apply')
        location = usb['locationID']
        # Darwin USB header location ID is LE at byte 24 (Wireshark 4.6.6).
        # Filter before writing to disk, excluding all other USB devices.
        capture_filter = 'link[24:4] = 0x' + location.to_bytes(4, 'little').hex()
        pcap = prefix.with_suffix('.pcapng')
        with prefix.with_suffix('.dumpcap.log').open('w') as log:
            process = subprocess.Popen([str(WS / 'dumpcap'), '-i', interface,
                '-f', capture_filter, '-s', '0', '-B', '8',
                '-a', f'duration:{duration + 20}', '-w', str(pcap)],
                stdout=log, stderr=log)
            try:
                for _ in range(100):
                    if pcap.exists() and pcap.stat().st_size:
                        break
                    if process.poll() is not None:
                        raise RuntimeError(prefix.with_suffix('.dumpcap.log').read_text())
                    time.sleep(.05)
                else:
                    raise TimeoutError('Capture did not start')
                time.sleep(.3)
                rc.ART = ART
                os.environ['ROUTE_PROBE_EQ'] = '1' if eq else '0'
                with contextlib.redirect_stdout(io.StringIO()):
                    report = rc.capture(label, uid, route, media=media, seek=seek,
                        duration=duration, yaw=yaw, hrtf=hrtf, headroom_db=headroom,
                        production=True)
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGINT)
                process.wait(timeout=5)
        if process.returncode:
            raise RuntimeError('USB capture failed')
        log_text = prefix.with_suffix('.dumpcap.log').read_text()
        if not re.search(r'received/dropped.*?: \d+/0 \(', log_text):
            raise ValueError('Capture drop count is not confirmed zero')
        after = metadata()
        after_usb = next(d for d in after['usb'] if d['USB Product Name'] == usb_product)
        if any(after_usb[k] != usb[k] for k in ('locationID', 'USB Address', 'idVendor', 'idProduct')):
            raise ValueError('USB device identity changed')
        if (device(after, uid)['streams'][0]['physical'] != configured_device['streams'][0]['physical']):
            raise ValueError('Negotiated output format changed')
        for stage in (('hal-output',) if route == 'off' else ('spatial-postrender', 'hal-output')):
            rc.read(label, stage)
        status = report['productionRender']
        if route != 'off' and (status['actualHRTF'] != hrtf or status['hrtfError']):
            raise ValueError(f'Unexpected actual HRTF: {status}')
        if route != 'off' and headroom is not None and (status['state'] != 2 or status['error'] or
                abs(status['preGain'] + headroom) > .001 or
                abs(status['postGain'] - headroom) > .001):
            raise ValueError(f'Headroom is not applied: {status}')
        if eq and (not report['probeEQ']['active'] or report['probeEQ']['error']):
            raise ValueError('EQ did not apply')
        result = {'original': original, 'configured': configured, 'after': after,
            'uid': uid, 'usb': usb, 'captureFilter': capture_filter,
            'interface': interface, 'requestedVolume': volume, 'requestedBits': bits,
            'pcap': str(pcap), 'label': label}
        prefix.with_suffix('.usb.json').write_text(json.dumps(result, indent=2, ensure_ascii=False))
        print(f'CAPTURED {label}: HAL + USB, actual HRTF={status["actualHRTF"]}, '
              f'headroom={headroom if route != "off" else "inactive"}, packets dropped=0', flush=True)
        return result
    except BaseException:
        for path in [*ART.glob(label + '.*'), *ART.glob(label + '-*.f32')]:
            path.unlink(missing_ok=True)
        raise
    finally:
        # Attempt both restorations even if one fails.
        errors = []
        for changed, operation, value in [(volume_changed, '--volume', original_volume),
                                          (bits_changed, '--bits', original_bits)]:
            if changed:
                try:
                    restored = metadata(operation, uid, value)
                    d = device(restored, uid)
                    if operation == '--bits':
                        assert d['streams'][0]['physical']['format']['bits'] == value
                    else:
                        v = next(v for v in d['volumes'] if v['channel'] == 0)
                        assert not v['scalarError'] and abs(v['scalar'] - value) < 1e-5
                except Exception as error:
                    errors.append(str(error))
        if previous_eq is None:
            os.environ.pop('ROUTE_PROBE_EQ', None)
        else:
            os.environ['ROUTE_PROBE_EQ'] = previous_eq
        if errors:
            raise RuntimeError('Device setting restoration failed: ' + '; '.join(errors))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('label')
    parser.add_argument('uid')
    parser.add_argument('route', choices=['native', 'shim', 'off'])
    parser.add_argument('--media', type=Path, required=True)
    parser.add_argument('--usb-product', required=True)
    parser.add_argument('--headroom', type=float, default=20)
    parser.add_argument('--hrtf', type=int, choices=[0, 1], default=0)
    parser.add_argument('--yaw', type=float, default=0)
    parser.add_argument('--seek', type=float, default=0)
    parser.add_argument('--duration', type=float, default=8)
    parser.add_argument('--volume', type=float)
    parser.add_argument('--bits', type=int)
    parser.add_argument('--eq', action='store_true')
    parser.add_argument('--interface', default='XHC2')
    args = parser.parse_args()
    capture(args.label, args.uid, args.route, args.media, args.usb_product,
        args.headroom, args.hrtf, args.yaw, args.seek, args.duration, args.volume,
        args.bits, args.eq, args.interface)


if __name__ == '__main__':
    main()

"""Protocol/analysis checks; no playback or device setting changes."""
import numpy as np

from usb_audio_analysis import compare_arrays, decode_pcm, pcm_formats


def rejects(call):
    try:
        call()
    except ValueError:
        return
    raise AssertionError('Invalid input accepted')


# Full-scale, sign-extension and padding boundaries in the two USB formats.
values = np.array([-8388608, -123456, -1, 0, 1, 123456, 8388607, 0], dtype=np.int32).reshape(-1, 2)
packed = b''.join(int(v).to_bytes(3, 'little', signed=True) for v in values.flat)
padded = (values.astype(np.int64) << 8).astype('<i4').tobytes()
for data, size in [(packed, 3), (padded, 4)]:
    decoded, pcm = decode_pcm(data, size, 24, 2)
    assert np.array_equal(decoded, values)
    assert np.array_equal(pcm, values / 8388608)
rejects(lambda: decode_pcm(packed[:-1], 3, 24, 2))
rejects(lambda: decode_pcm(bytes([1]) + padded[1:], 4, 24, 2))
rejects(lambda: decode_pcm(packed, 3, 25, 2))

# UAC2 AS descriptor: stereo PCM, 24 significant bits in a four-byte slot.
descriptor = ('090404010201022000' '10240101000101000000020300000000'
              '062402010418' '07050505880101')
formats = pcm_formats(descriptor)
assert len(formats) == 1
assert {k: formats[0][k] for k in ('interface', 'alternate', 'channels', 'bits', 'containerBytes', 'endpoint')} == {
    'interface': 4, 'alternate': 1, 'channels': 2, 'bits': 24, 'containerBytes': 4, 'endpoint': 5}
rejects(lambda: pcm_formats(descriptor[:-2]))

# A shared delay preserves equality. Gain fitting and ear-specific shifts must
# never turn the reported raw null into an equality claim.
rng = np.random.default_rng(20261024)
source = rng.normal(0, .01, (48000 * 4, 2))
delayed = np.vstack([np.zeros((123, 2)), source])
metric, _, _ = compare_arrays(source, delayed)
assert metric['lagSamples'] == 123 and metric['exactSamples']
metric, _, _ = compare_arrays(source, delayed * .25)
assert not metric['exactSamples'] and abs(metric['bestCommonGain'] - .25) < 1e-14
assert metric['rawMaxAbsoluteError'] > .001 and metric['gainAdjustedMaxError'] < 1e-14
different_ears = delayed.copy()
different_ears[:, 1] = np.roll(different_ears[:, 1], 1)
assert not compare_arrays(source, different_ears)[0]['exactSamples']
rejects(lambda: compare_arrays(source, np.full_like(source, np.nan)))
rejects(lambda: compare_arrays(source, np.zeros_like(source)))
print('PASS: USB descriptor, PCM decoding, padding, shared delay and raw-null integrity')

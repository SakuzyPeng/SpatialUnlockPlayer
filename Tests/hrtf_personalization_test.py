"""Silent real-app HRTF transitions on an ordinary headphone output."""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'Tests/Artifacts/hrtf-availability'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True)
parser.add_argument('--app', type=Path, default=ROOT / 'build/Products/Diagnostics/SpatialUnlock Player.app')
parser.add_argument('--require-no-native', action='store_true')
args = parser.parse_args()
devices = json.loads(subprocess.check_output([str(ROOT / 'build/tests/route-probe/route-probe'), '--devices'], text=True))
target = next(d for d in devices if d['uid'] == args.output)
assert not target['hasSpen'], 'Use the ordinary headphone path for this test'
if args.require_no_native:
    assert not any(d['hasSpen'] for d in devices), 'A native spatial-audio output is still connected'

def a(action, **values): return dict(action=action, **values)
def ready(): return a('awaitReady')
def state(**values): return a('awaitState', expect=values)
def hrtf(mode, actual):
    return [a('advancedHRTF', value=mode), ready(),
            state(advancedHRTFMode=mode, advancedHRTFActual=actual, advancedHRTFError=0)]

media = ROOT / 'Tests/Artifacts/route-comparison/broadband-hot-5.1.wav'
steps = [a('output', value=args.output), a('mode', value='headphones'), a('volume', value=0),
         a('add', paths=[str(media), str(media)]), ready(), a('play'),
         state(advancedHRTFActual=0, advancedHRTFError=0)]
steps += hrtf('personalized', 1) + hrtf('generic', 0) + hrtf('system', 0) + hrtf('personalized', 1)
steps += [a('mode', value='off'), ready(), state(advancedHeadroomState=5, advancedHRTFActual=-1),
          a('mode', value='headphones'), ready(), state(advancedHRTFActual=1),
          a('eqImport', path=str(ROOT / 'Tests/Fixtures/Sony MDR-MV1 ParametricEq.txt')),
          state(eqApplied=True, eqError=0, advancedHRTFActual=1),
          a('advancedHeadroomDB', value=7.3), ready(),
          state(advancedHeadroomState=2, advancedHRTFActual=1, advancedHeadroomError=0),
          a('next'), ready(), state(advancedHRTFActual=1),
          a('pause'), a('seek', value=4), ready(),
          a('assert', expect=dict(wantsToPlay=False, minPosition=3.9, maxPosition=4.1)),
          a('advancedReset'), ready(), state(advancedHRTFMode='system', advancedHeadroomMode='system'),
          a('play'), state(advancedHRTFActual=0)]
ART.mkdir(parents=True, exist_ok=True)
script, result = ART / 'app-transitions.json', ART / 'app-transitions-result.json'
script.write_text(json.dumps(steps, indent=2)); result.unlink(missing_ok=True)
env = dict(os.environ)
for name in ['DYLD_INSERT_LIBRARIES', 'SPATIALUNLOCKPLAYER_TEST_KEEP_OPEN', 'SPATIALUNLOCKPLAYER_TEST_RESTORE_SESSION']:
    env.pop(name, None)
env.update(SPATIALUNLOCKPLAYER_TEST_SCRIPT=str(script), SPATIALUNLOCKPLAYER_TEST_RESULT=str(result))
with (ART / 'app-transitions.log').open('w') as log:
    subprocess.run([str(args.app / 'Contents/MacOS/SpatialUnlockPlayer')], env=env,
                   stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
report = json.loads(result.read_text())
assert report['passed'], report['failure']
assert not report['injectedLibraries']
assert all(not step['state']['advancedHRTFError'] for step in report['steps'])
print(f'PASS: {len(steps)} silent app steps; personalized/generic/system, spatial off/on, EQ, headroom, rebuild and reset')

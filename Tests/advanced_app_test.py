"""Real Diagnostics application: per-device advanced settings and playback rebuilds."""
from pathlib import Path
import argparse
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'Tests/Artifacts/advanced-audio'
ART.mkdir(parents=True, exist_ok=True)
parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, default=ROOT / 'build/Products/Diagnostics/SpatialUnlock Player.app')
parser.add_argument('--fiio', required=True, help='UID of the ordinary stereo DAC/headphone output')
parser.add_argument('--airpods', required=True, help='UID of the native spatial-audio output')
args = parser.parse_args()
binary = args.app / 'Contents/MacOS/SpatialUnlockPlayer'
if not binary.is_file():
    parser.error('Build the Diagnostics app first, or pass --app APP_PATH')


def a(action, **kw): return dict(action=action, **kw)
def check(**kw): return a('assert', expect=kw)
def ready(): return a('awaitReady')
def applied(**kw): return a('awaitState', expect=dict(advancedHeadroomState=2, advancedHeadroomError=0, **kw))


def run(name, steps, restore=False):
    script, result = ART / (name + '.json'), ART / (name + '-result.json')
    script.write_text(json.dumps(steps, ensure_ascii=False, indent=2)); result.unlink(missing_ok=True)
    env = dict(os.environ)
    env.pop('DYLD_INSERT_LIBRARIES', None); env.pop('SPATIALUNLOCKPLAYER_TEST_KEEP_OPEN', None)
    env.update(SPATIALUNLOCKPLAYER_TEST_SCRIPT=str(script), SPATIALUNLOCKPLAYER_TEST_RESULT=str(result),
               SPATIALUNLOCKPLAYER_TEST_RESTORE_SESSION='1' if restore else '0')
    with (ART / (name + '.log')).open('w') as log:
        subprocess.run([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
    report = json.loads(result.read_text()); assert report['passed'], (name, report['failure'])
    assert not report['injectedLibraries']
    for step in report['steps']:
        state = step['state']
        assert state['advancedUID'] == state['outputUID']
        if state['advancedHeadroomState'] == 2:
            assert abs(state['advancedPreGain'] + state['advancedHeadroomDB']) < .001
            assert abs(state['advancedPostGain'] - state['advancedHeadroomDB']) < .001
        if state['advancedHRTFMode'] == 'personalized' and state['advancedHRTFActual'] == 0 and state['playing']:
            assert '通用' in state['advancedHRTFStatus']
    print(f'PASS {name}: {len(steps)} app steps', flush=True)
    return report


media = ROOT / 'Tests/Artifacts/posebridge-integration/center-5.1.wav'
sony = ROOT / 'Tests/Fixtures/Sony MDR-MV1 ParametricEq.txt'
first = run('transitions', [
    a('output', value=args.fiio), a('mode', value='headphones'), a('volume', value=.02),
    check(advancedHeadroomMode='system', advancedHRTFMode='system', advancedHeadroomDB=20),
    a('add', paths=[str(media),str(media)]), ready(), a('pause'), a('seek', value=4), ready(),
    a('advancedHeadroomDB', value=7.3), ready(),
    check(advancedHeadroomMode='custom',advancedHeadroomDB=7.3,wantsToPlay=False,minPosition=3.9,maxPosition=4.1),
    a('play'), applied(), a('advancedHRTF', value='generic'), ready(), applied(advancedHRTFActual=0),
    a('advancedHRTF', value='personalized'), ready(), applied(),
    a('mode',value='off'), ready(), check(advancedHeadroomState=5,advancedHRTFMode='personalized'),
    a('mode',value='headphones'), ready(), applied(),
    a('output',value=args.airpods), ready(), check(advancedHeadroomMode='system',advancedHRTFMode='system'),
    a('advancedHeadroomDB',value=20), ready(), a('advancedHRTF',value='generic'),ready(),applied(advancedHRTFActual=0),
    a('output',value=args.fiio),ready(),applied(advancedHeadroomDB=7.3,advancedHRTFMode='personalized'),
    a('advancedReset'),ready(),check(advancedHeadroomMode='system',advancedHRTFMode='system',advancedHeadroomDB=20),
    a('advancedHeadroomDB',value=5),ready(),a('advancedHRTF',value='generic'),ready(),applied(),
    a('eqImport',path=str(sony)),a('awaitState',expect=dict(eqApplied=True,eqError=0,advancedHeadroomState=2)),
    a('next'),ready(),applied(eqApplied=True),a('previous'),ready(),applied(eqApplied=True),
    a('pause'),a('seek',value=4),ready(),
    a('advancedHeadroomDB',value=10),ready(),check(wantsToPlay=False,minPosition=3.9,maxPosition=4.1),
    a('advancedHeadroomDB',value=5),ready(),
    a('output',value=args.airpods),ready(),check(advancedHeadroomDB=20,advancedHRTFMode='generic',wantsToPlay=False),
    a('output',value=args.fiio),ready(),check(advancedHeadroomDB=5,advancedHRTFMode='generic',wantsToPlay=False)
])
run('restart',[
    ready(),check(advancedUID=args.fiio,advancedHeadroomMode='custom',advancedHeadroomDB=5,
                  advancedHRTFMode='generic',wantsToPlay=False,minPosition=3.9,maxPosition=4.1),
    a('play'),applied(eqApplied=True),a('output',value='system'),ready(),
    a('output',value=args.airpods),ready(),applied(advancedHeadroomDB=20),
    a('advancedReset'),ready(),check(advancedHeadroomMode='system',advancedHRTFMode='system'),
    a('output',value=args.fiio),ready(),applied(advancedHeadroomDB=5,advancedHRTFMode='generic'),a('pause')
],restore=True)
run('reset-restart',[
    ready(),check(advancedHeadroomDB=5,wantsToPlay=False),
    a('output',value=args.airpods),ready(),check(advancedHeadroomMode='system',advancedHRTFMode='system'),
    a('output',value=args.fiio),ready(),a('advancedReset'),ready(),
    check(advancedHeadroomMode='system',advancedHRTFMode='system')
],restore=True)
print('PASS: actual playback rebuilds, two UIDs, system-default alias, custom zero/default semantics, EQ coexistence and restart persistence')

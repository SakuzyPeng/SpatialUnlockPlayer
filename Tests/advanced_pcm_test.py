"""Shipping advanced renderer vs real AirPods/FIIO HAL, using existing short media."""
import argparse
import json
import os
from pathlib import Path

from route_comparison import ART, capture, compare

parser = argparse.ArgumentParser()
parser.add_argument('--reuse', action='store_true', help='Analyze already completed captures when available')
parser.add_argument('--fiio', required=True, help='UID of the ordinary stereo DAC/headphone output')
parser.add_argument('--airpods', required=True, help='UID of the native spatial-audio output')
args = parser.parse_args()
devices = [('airpods',args.airpods,'native'), ('fiio',args.fiio,'shim')]
result = {}


def take(label, uid, route, media, db=None, seek=0, duration=8, yaw=0, production=True, hrtf=0):
    path = ART / (label + '.json')
    if args.reuse and path.exists():
        r = json.loads(path.read_text())
        if r.get('device', {}).get('uid') != uid:
            raise ValueError(f'{label}: cached capture belongs to another output; rerun without --reuse')
    else:
        r = capture(label,uid,route,media=media,seek=seek,duration=duration,yaw=yaw,hrtf=hrtf,
                    headroom_db=db,production=production)
    assert r['ready'] and not r['error'] and not r['poseErrors']
    if production and db is not None:
        s = r['productionRender']; assert s['state']==2 and not s['error'] and not s['rollbackFailed'],s
        assert abs(s['preGain']+db)<.001 and abs(s['postGain']-db)<.001
    return r


def pair(key, media, db=20, seek=0, duration=8, yaw=0):
    labels=[]
    for suffix,uid,route in devices:
        label=f'advanced-{key}-{suffix}'
        r=take(label,uid,route,media,db,seek,duration,yaw)
        assert r['productionRender']['actualHRTF']==0
        if os.environ.get('ROUTE_PROBE_EQ')=='1':
            assert r['probeEQ']['active'] and not r['probeEQ']['error']
            assert r['probeEQ']['minFrames']==r['probeEQ']['maxFrames']==512
        labels.append(label)
    values={stage:compare(*labels,stage) for stage in ['spatial-postrender','hal-output']}
    assert all(v['bitIdentical'] for v in values.values()),key
    result[key]=values; print('PASS',key,'HAL bit-identical',flush=True)


for db in [0,5,10,15,20,7.3]:
    pair('hot-'+str(db).replace('.','p'), ART/'broadband-hot-5.1.wav', db)
pair('low-20', ART/'broadband-5.1.wav')
for source in ['atmos','apac16']:
    media=Path(json.loads((ART/(source+'-fiio-personal.json')).read_text())['media'])
    pair(source+'-20',media,seek=30,duration=7)
os.environ['ROUTE_PROBE_EQ']='1'
pair('eq-yaw45-7p3',ART/'broadband-hot-5.1.wav',db=7.3,yaw=45)
os.environ.pop('ROUTE_PROBE_EQ',None)

for suffix,uid,route in devices:
    labels=[]
    for production in [False,True]:
        label='advanced-default-'+suffix+('-production' if production else '-reference')
        take(label,uid,route,ART/'broadband-hot-5.1.wav',production=production,hrtf=None)
        labels.append(label)
    values={stage:compare(*labels,stage) for stage in ['spatial-postrender','hal-output']}
    assert all(v['bitIdentical'] for v in values.values())
    result['default-'+suffix]=values
    print('PASS default preservation',suffix,flush=True)

(ART/'advanced-pcm-summary.json').write_text(json.dumps({'passed':True,'cases':result},indent=2))

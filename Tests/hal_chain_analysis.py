"""Validate the completed HAL gain-placement experiment without playing audio.

Reads the named local route-comparison captures and emits hal-summary.json.
The common integer delay is fitted; bit equality never uses fitted gain or EQ.
"""
import hashlib
import json

import numpy as np

from route_comparison import ART, ROOT, compare, read

CHAIN = ['spatial-postrender', 'au-aufx-vrq2-0-post', 'au-aufx-ldnm-0-post',
         'au-aufx-cfrk-0-post', 'au-aufx-vrq2-1-post', 'au-aumx-mcmx-2-post', 'hal-output']


def report(label):
    return json.loads((ART / (label + '.json')).read_text())


def parameters(label, stage):
    record = next(r for r in report(label)['records'] if r['kind'] == stage)
    return {p['id']: p['value'] for p in record['parameters']}


def main():
    baseline = {}
    interventions = {}
    for name, a, b in [
        ('hot', 'hal-hot-airpods-chain', 'hal-hot-fiio-chain'),
        ('atmos', 'hal-atmos-airpods', 'hal-atmos-fiio'),
        ('apac16', 'hal-apac16-airpods', 'hal-apac16-fiio'),
    ]:
        for label, expected in [(a, (-20, 20)), (b, (0, 0))]:
            for stage, gain in zip(['au-aufx-vrq2-0-post', 'au-aufx-vrq2-1-post'], expected):
                assert parameters(label, stage)[7] == gain, (label, stage)
        baseline[name] = {stage: compare(a, b, stage) for stage in CHAIN}
        assert baseline[name]['spatial-postrender']['bitIdentical'], name
        assert not baseline[name]['hal-output']['bitIdentical'], name

    for name, a, b in [
        ('fiio-to-airpods', 'hal-hot-airpods-chain', 'hal-hot-fiio-headroom20'),
        ('airpods-to-fiio', 'hal-hot-fiio-chain', 'hal-hot-airpods-headroom0'),
        ('atmos', 'hal-atmos-airpods', 'hal-atmos-fiio-headroom20'),
        ('apac16', 'hal-apac16-airpods', 'hal-apac16-fiio-headroom20'),
        ('atmos-on-request', 'hal-atmos-personal-airpods', 'hal-atmos-personal-fiio-headroom20'),
    ]:
        interventions[name] = {stage: compare(a, b, stage) for stage in CHAIN}
        assert all(v['bitIdentical'] for v in interventions[name].values()), name
        for result in interventions[name].values():
            if result['stage'] == 'spatial-postrender':
                assert result['hrtfA']['value'] == result['hrtfB']['value'] == 0

    interventions['low-level'] = {
        stage: compare('broadband-airpods-generic-b', 'hal-low-fiio-headroom20', stage)
        for stage in ('spatial-postrender', 'hal-output')
    }
    assert all(v['bitIdentical'] for v in interventions['low-level'].values())

    observer_checks = {}
    for reference, traced in [('hot-airpods', 'hal-hot-airpods-chain'),
                              ('hot-fiio-personal', 'hal-hot-fiio-chain')]:
        observer_checks[reference] = {stage: compare(reference, traced, stage)
                                      for stage in ('spatial-postrender', 'hal-output')}
        assert all(v['bitIdentical'] for v in observer_checks[reference].values())

    stages = {}
    for label in ['hal-hot-airpods-chain', 'hal-hot-fiio-chain']:
        stages[label] = []
        for source, dest in zip(CHAIN, CHAIN[1:]):
            stages[label].append(compare(label, label, source, dest))
        assert stages[label][1]['lagSamples'] == 144
        assert stages[label][2]['lagSamples'] == 34
        assert stages[label][-1]['bitIdentical']

    metadata = {}
    labels = set()
    for collection in (baseline, interventions, observer_checks):
        for comparisons in collection.values():
            for result in comparisons.values():
                labels.update([result['a'], result['b']])
    for label in sorted(labels):
        d = report(label)
        metadata[label] = {k: d.get(k) for k in ('device', 'route', 'hrtfOverride', 'headroomOverrideDB',
            'volume', 'traceUnits', 'sourceSHA256', 'systemVersion', 'queueSpatial', 'poseErrors')}
        metadata[label]['stages'] = []
        for stage in CHAIN:
            if not any(r['kind'] == stage and r['frames'] for r in d['records']):
                continue
            _, r, pcm = read(label, stage)
            metadata[label]['stages'].append({
                **{k: r.get(k) for k in ('kind', 'componentName', 'parameters', 'bypass', 'gainOverrides',
                    'lastRequestedGain', 'properties', 'sampleRate', 'formatFlags', 'frames')},
                'peak': float(np.max(np.abs(pcm))),
                'blockSizes': sorted({b[1] for b in r['blocks']}),
            })
    sources = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in [
        'Tests/route_probe.h', 'Tests/route_probe_shim.c', 'Tests/route_probe.m',
        'Tests/route_probe_build.sh', 'Tests/route_comparison.py', 'Tests/hal_chain_analysis.py']}
    result = {'date': '2026-10-24', 'assertionsPassed': True,
        'baseline': baseline, 'interventions': interventions, 'observerChecks': observer_checks,
        'adjacentStages': stages, 'captures': metadata, 'sourceSHA256AtAnalysis': sources}
    (ART / 'hal-summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    for name, values in interventions.items():
        r = values['hal-output']
        print(f'{name}: HAL bit-identical, {r["comparedFrames"]} stereo frames, max error {r["rawMaxAbsoluteError"]}')
    print('Baseline differences, unchanged observer output, both causal directions, and stage delays verified.')


if __name__ == '__main__':
    main()

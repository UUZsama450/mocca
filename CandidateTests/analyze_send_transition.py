#!/usr/bin/env python3
"""Inspect external presentation-layer samples; this does not alter app geometry."""
import argparse
import json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('run', type=Path)
p.add_argument('--require-no-drop', action='store_true')
a = p.parse_args()
frames, events = [], []
for line in (a.run / 'app-console.log').read_text(errors='replace').splitlines():
    for marker, dest in [('SEND_FRAME ', frames), ('SEND_NATIVE_EVENT ', events)]:
        if marker in line:
            try:
                dest.append(json.loads(line.split(marker, 1)[1]))
            except json.JSONDecodeError:
                pass
for name, values in [('frames', frames), ('events', events)]:
    (a.run / (name + '.json')).write_text(json.dumps(values, indent=2))
transitions = []
for index in range(1, len(frames)):
    before, first = frames[index - 1], frames[index]
    if first['total'] != before['total'] + 2:
        continue
    old_tail = before['total'] - 1
    def text_y(frame):
        row = next((r for r in frame['rows'] if r['item'] == old_tail), None)
        return row['texts'][0]['shown'][1] if row and row['texts'] else None
    origin = text_y(before)
    samples = [(f['uptime'] - first['uptime'], text_y(f)) for f in frames[index:]
               if 0 <= f['uptime'] - first['uptime'] <= 1 and f['total'] == first['total']]
    samples = [(t, y) for t, y in samples if y is not None]
    down = max((y - origin for _, y in samples), default=0) if origin is not None else None
    reversals = [max(0, y2 - y1) for (_, y1), (_, y2) in zip(samples, samples[1:])]
    transitions.append(dict(uptime=first['uptime'], previousCount=before['total'],
        sampleCount=len(samples), initialTextY=origin, maximumDropFromOrigin=down,
        largestDownwardStep=max(reversals, default=0), samples=samples))
report = dict(frameCount=len(frames), eventCount=len(events), transitions=transitions)
(a.run / 'trajectory.json').write_text(json.dumps(report, indent=2))
print(json.dumps({**report, 'transitions': [{k: v for k, v in t.items() if k != 'samples'} for t in transitions]}, indent=2))
if a.require_no_drop:
    assert transitions, 'No recorded send transition'
    for t in transitions:
        assert t['sampleCount'] >= 10 and t['maximumDropFromOrigin'] is not None, 'Insufficient old-text observations'
        assert t['maximumDropFromOrigin'] <= 1, 'Old text dropped below its pre-send position'
        assert t['largestDownwardStep'] <= 1, 'Old text reversed direction during send'

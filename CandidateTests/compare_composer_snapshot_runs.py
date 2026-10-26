"""Compare completed 5255/5256 simulator fixture runs, including real measurements.

ComposerLayoutProbeHarness checks every row before/after keyboard dismissal:
only 240pt estimates may become 48pt fixture rows, with exact prefix displacement.
Raw post-dismiss offsets therefore need not match between runs that measure
different newly exposed rows. Keep those raw values and compare animation-end
geometry separately; never hide the distinction in a timing/FPS claim.
"""
from pathlib import Path
import json, sys

folder = Path(sys.argv[1])
reports = [json.loads((folder / f'{mode}-{repeat}.json').read_text())
           for repeat, order in enumerate([['baseline', 'candidate'], ['candidate', 'baseline']])
           for mode in order]
assert all(r['status'] == 'PASS' and not r['failures'] for r in reports)
close = lambda values: max(values) - min(values) < 1
comparisons = []
for name in [c['name'] for c in reports[0]['cases']]:
    by_mode = {mode: [next(c for c in r['cases'] if c['name'] == name)
                      for r in reports if r['mode'] == mode]
               for mode in ['baseline', 'candidate']}
    cases = [c for group in by_mode.values() for c in group]
    initial = [c['initialOffset'] for c in cases]
    final = [c['finalOffset'] for c in cases]
    measured = [c['newlyMeasuredRows'] for c in cases]
    # History must retain its raw offset. Bottom pin moves with content height.
    normalized = [c['finalOffset'] + (240 - 48) * c['newlyMeasuredRows']
                  if '-bottom-' in name else c['finalOffset'] for c in cases]
    animation_ends = {
        key: [c['frames'][key][-1] for c in cases]
        for key in ['offsets', 'anchorPositions', 'contentHeights', 'bottomGaps']
    }
    animation_matches = all(close(v) for v in animation_ends.values())
    geometry = close(initial) and animation_matches and close(normalized)
    comparisons.append({
        'case': name,
        'geometryMatchesWithVerifiedMeasurements': geometry,
        'rawInitialAndFinalOffsetsMatch': close(initial) and close(final),
        'rawFinalOffsets': final,
        'newlyMeasuredRowsAfterKeyboardDismissal': measured,
        'measurementAdjustedFinalOffsets': normalized,
        'animationEndGeometry': animation_ends,
        'baselineControllerMsPerUpdate': [c['inclusiveMainThreadMs']['controller'] / c['counts']['controller'] for c in by_mode['baseline']],
        'candidateControllerMsPerUpdate': [c['inclusiveMainThreadMs']['controller'] / c['counts']['controller'] for c in by_mode['candidate']],
        'baselineFullInvalidations': [c['counts'].get('layout.fullItemInvalidation', 0) for c in by_mode['baseline']],
        'candidateFullInvalidations': [c['counts'].get('layout.fullItemInvalidation', 0) for c in by_mode['candidate']],
    })
summary = {
    'allRunsPassed': True,
    'geometryMatches': all(c['geometryMatchesWithVerifiedMeasurements'] for c in comparisons),
    'comparisons': comparisons,
    'measurementBasis': 'Each original fixture run verifies every row width, estimate-to-real height change (240 to 48), exact prefix displacement, bottom pin and history offset. Animation-end geometry is before focus dismissal; finalOffset is after dismissal.',
    'limits': 'Optimized simulator component with synthetic Text rows. Inclusive controller wall time is not whole-frame CPU, GPU presentation or physical-phone FPS. Animation and text-rendering product sources are unchanged.'
}
(folder / 'performance-comparison.json').write_text(json.dumps(summary, indent=2) + '\n')
assert summary['geometryMatches']
print(json.dumps({'allRunsPassed': True, 'geometryMatches': True,
                  'rawPostDismissDifferences': [c['case'] for c in comparisons if not c['rawInitialAndFinalOffsetsMatch']]}))

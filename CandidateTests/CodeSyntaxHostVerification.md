# Code syntax highlighting 4995: host verification

Run from this candidate with:

```sh
/usr/bin/python3 CandidateTests/CodeSyntaxRunHostTests.py
```

The optional first argument supplies a local HighlighterSwift checkout. It must
be the clean upstream `3.1.0` revision
`fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0`. The runner copies the complete
`Mocca/CodeSyntaxHighlighter.swift` unchanged into a temporary Swift package,
links the real upstream `Highlighter` product, and builds/runs a macOS command-line
executable. It writes all generated files, logs, and source hashes to ignored
`work/verification/code-syntax-host/`. No simulator or iOS application is run.

The final 2026-09-10 run passed **18,953 assertions** against production source
SHA-256 `e63645ebf2a6a25de977e021a95b2b043be7b5544363c1a5164616ceac3df643`.
Its budgets are 8,192 UTF16 units while streaming, 32,768 after completion, and
3,000 returned colour runs. The runner reads those constants directly from the
production file and passes them to the boundary fixtures.

Coverage:

- Fourteen common grammars; aliases and empty/unknown/plaintext fallback.
- UTF16 bounds and surrogate safety; Chinese, emoji sequences, combining marks,
  CRLF, literal HTML entities, and canonically equivalent strings whose raw
  UTF16 offsets differ.
- Unterminated strings/comments and many streaming prefixes, each compared with
  the same exact source in settled mode; full completion and fold-prefix/full
  source cache round trips.
- Distinct light/dark palettes and 96 concurrent requests with mixed source,
  theme, grammar, and streaming state.
- Exact/over-limit UTF16 inputs, streaming-to-settled eligibility, many-token
  fallback, and correctness after 48 distinct settled cache insertions.

Observed release-host timings on macOS 26.5.2 x86_64 (single run, no performance
pass threshold):

| Operation | Host time |
| --- | ---: |
| Engine startup and first small Swift block | 117.225 ms |
| First settled 100-line block | 25.507 ms |
| 50 warm settled requests, total | 2.032 ms |
| 10 streaming requests for the 100-line block, total | 251.936 ms |
| 2,978 repeated token-rich statements, then fallback | 480.899 ms |

Warm/full-block benchmarks call the production actor directly without per-run
test assertions. The prefix batch timings in `results.log` include semantic
checks. These are host observations, **not iPhone responsiveness or frame-time
acceptance**. The many-token result shows that the returned-run budget bounds
the output and cache; it does not prevent the engine's preceding parsing work.

An earlier bounded budget experiment, recorded separately in
`budget-benchmark.log` and `budget-benchmark-manifest.json`, compared 8/16/32 Ki
inputs before narrowing the production budgets. It ran alongside an app Release
build, so CPU contention and host architecture limit performance interpretation:

| Approximate input size | Dense tokens, three host samples | Single comment, three host samples |
| --- | --- | --- |
| 8 Ki UTF16 | 191.6 / 161.8 / 158.3 ms; 2,976 runs | 6.0 / 5.3 / 5.8 ms |
| 16 Ki UTF16 | 315.2 / 307.4 / 308.0 ms; 5,956 runs | 11.3 / 10.3 / 10.5 ms |
| 32 Ki UTF16 | 604.7 / 608.2 / 594.5 ms; output fallback | 20.8 / 20.4 / 20.2 ms |

These observations motivated the lower input and output bounds. They do not
establish a parser time limit; expensive supported input can still take time.

The private cache counters are not exposed: churn tests verify correct results
after pressure, but do not claim measured cache entry/byte/run bounds. This
harness also does not verify UIKit text geometry, font invariance, scrolling,
fold UI, cancellation of in-progress JavaScript, or physical-device appearance.

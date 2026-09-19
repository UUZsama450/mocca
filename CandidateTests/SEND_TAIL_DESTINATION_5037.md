# 5037 measured send-tail experiment

**Held for investigation. Not accepted for device installation or merging.**

Based directly on accepted phone build 5036, commit `06911104abb3c10d599d0ca2137849aa0d4ef683`; branch `codex/send-tail-destination-5037`.

## Change

Within `scheduleUserMessageSendPositioning`, a bounded, fully measured current window may address its final bottom destination directly after user-message placement. This removes the assistant-row intermediate scroll when its geometry and the real native destination already agree. Other cases retain the existing row-materialization path and all existing post-scroll landing/user-ownership checks.

Only this product function and the four project build-number settings differ from 5036. There are no new tasks, timers, state properties, or per-frame processing.

## Evidence and limitations

- In controlled 429- and 853-character sends, two scroll commands replaced the former three, with exact concrete/native bottom landing.
- Short send, keyboard cycles, history position/return, tools/model round trips, and a keyboard-hidden send with a complete growing reply have positive runtime samples. Sixteen valid/stale/invalid geometry policy cases pass.
- The initial user-placement handoff remains; this does not make every send one uninterrupted animation.
- Reply growth overlapping the landing can still leave follow detached in both 5036 and 5037.
- A later 5037 test failed to show the software keyboard before sending, while the matching 5036 sequence reached both sends. The new target-selection code had not run; the cause remains unproven. This blocks calling the candidate regression-free or accepted.
- Debug and signed arm64 Release artifacts build and verify, but 5037 was not installed to the phone. Keep the accepted 5036 device baseline.

Full local evidence, runtime commands, videos, exact hashes and superseded failures:
`work/verification/send-tail-destination-5037/REPORT.md` in the main Mocca checkout.

Policy reproduction on macOS: run `CandidateTests/check_send_tail_destination.py` with a Python interpreter and an output-directory argument. It extracts the actual Swift predicate and exercises matching, stale, incomplete, nonfinite, and oversized destination geometry. The XCTest driver uses synthetic conversations and a localhost SSE fixture; see the verification directory for the standalone Xcode test project and capture runners.

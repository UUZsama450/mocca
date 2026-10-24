# Build 5248 validation

The application source was compared with the frozen source used for the installed 1.0.6 (5248) build. The project default build number is aligned to 5248 for both app and extension; portable signing and sponsorship defaults remain unchanged.

## Automated and visual checks

- Sponsorship build gate: all five configuration cases passed (disabled, enabled, missing, unresolved and invalid). The harness was updated to omit APIs removed with consumable-purchase restoration; product commerce behavior is unchanged.
- Transcript layout: 13 controller regression scenarios and full-app composer UI checks passed. Synthetic repeated footer updates avoid full item invalidation when row positions stay unchanged. Required width, content, structural and short-content alignment invalidations remain.
- Prompt and motion suite: 17 tests passed (six composer scenarios, ten search/theme/preference checks, and one prompt-editing UI workflow). The six composer scenarios were rerun successfully with growth and shrink assertions.
- Build 5248 regression: the six composer scenarios and prompt editing workflow passed again. Four group-control UI scenarios passed: animation enabled/disabled, at the bottom/reading history, each expanding and collapsing the panel. Historical reading offsets remained stable.
- Simulator video was inspected for intermediate shell positions and matching transcript movement; final alert screenshots confirmed exactly three actions and red Discard last.
- Default light/dark controls and other theme palettes were checked. OCR uses the regular body font; custom search prompts and preference persistence remain covered.

The initial group fixture incorrectly treated final layout geometry as presentation geometry. Final checks separate target dimensions from sampled transcript offsets, with rendered shell motion checked in video; the product animation curve was not changed to satisfy that assertion.

## Reproduction

Prepare an isolated host with `/usr/bin/python3 CandidateTests/prepare_group_motion_host.py <isolated-host>` and run the generated `SearchPromptQA` scheme on an iOS simulator. Select `SearchToolPromptTests`, `ComposerIndependentMotionTests`, `GroupComposerMotionUITests`, and `SearchToolPromptUITests/testDraftExitSaveDiscardRestoreAndRelaunch`. Simulator signing must remain enabled with ad-hoc identity (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES`) for test-container Keychain persistence. Sampling helpers run only in the synthetic test host.

## Evidence limits

Build 5248 was installed in place and launched on a physical device. The preceding independent composer/message animation received positive physical-device feedback. The new group-panel motion has simulator functional and rendered-frame evidence; installation alone is not acceptance of its physical-device feel. No physical-device FPS, power, full live-network streaming, or system Reduce Motion toggle measurement is claimed. Search answer quality was not benchmarked against external models.

Private device logs, signing assets, chat data and generated build outputs are excluded from the public source.

# Simple navigation: isolate drawer observation

Baseline: 5050 / `e36e4378c5e30333d4c4cb8b34d847d34ece7ef8`.

In simple navigation mode, constructing the bottom-button overlay previously
read `model.isDrawerPresented` in `ChatView.body`, even when the button was
hidden at the latest bottom. A semantic drawer toggle could therefore
invalidate the transcript's owner for a button-only visibility decision.

`DrawerAwareQuickReturnToBottom` now owns that read and the animation value.
ChatView supplies drawer-independent eligibility, bottom padding, and the
existing return action. The existing conditional insertion/removal, transition
parameters, animation, button implementation, and navigation action are kept.
No additional state, tasks, caches, preference switches, or display links are
introduced. The behavioral change is confined to `Mocca/RootView.swift`; the
project build number is advanced from 5050 to 5051 for this authorized install.

The prior streaming/keyboard arrow-flicker fix remains intact:
`updateQuickReturnToBottomVisibility` and `shouldKeepNativeBottomPosition` are
byte-identical to 5050. Genuine history reading and accepted return-to-bottom
commands retain the existing visibility policy.

## Focused checks

```sh
/usr/bin/python3 CandidateTests/check_simple_navigation_drawer_isolation.py /absolute/path/to/output/isolation
/usr/bin/python3 CandidateTests/check_simple_arrow_visibility.py /absolute/path/to/output/arrow-policy
```

The first check extracts actual baseline/candidate declarations and overlay
construction, compiles them with SwiftUI and Observation on the host, and checks:

- 256 combinations of navigation mode, content presence, drawer state, picker,
  sheet, later history, and requested button visibility preserve the decision.
- On both opening and closing, the baseline parent observes the drawer even
  when the button is hidden. The candidate parent does not; the candidate leaf
  observes it only when base eligibility is true.
- The callback remains forwarded to the parent action. Transition constants,
  the button implementation, bottom-follow policy, drawer driver and handoff,
  and the complete Markdown source remain unchanged.

The harness explicitly replaces environment injection with an observable model
parameter and supplies a small button stand-in. These are view-construction and
dependency checks, not phone rendering, physical taps, intermediate animation
pixels, or frame-time measurements.

The existing arrow-policy check exercises 14 scenarios, including streaming and
keyboard geometry while following, native finger takeover, history, later
windows, and keeping the arrow until an accepted return reaches the exact bottom.

## Physical acceptance still required

The user's current-phone feedback was for selecting **Never show**, not for this
new implementation. With the candidate, verify **Simple** mode's held drag and
release settle, and then the visible button during history reading, its return
action, streaming, keyboard transitions, reaction picker, and message sheet.
Build/host checks must not be reported as measured FPS or phone acceptance.

Signed generic iOS Release build 5051 passed and was installed in place on the
iPhone 17 Pro using `com.uuzsama450.mocca.migration`. Installed-version readback
confirmed 5051, and the main app plus GenerationActivityExtension were running.
The formal bundle remains 5029. No uninstall, data clear, or chat-store copies
were performed; byte-identical chat preservation was not measured.

Build/sign/install/launch are verified. New-candidate interaction and frame time
remain pending user acceptance. Evidence is kept outside the checkout at
`work/verification/simple-navigation-drawer-isolation-20260919/` in the parent
repository.

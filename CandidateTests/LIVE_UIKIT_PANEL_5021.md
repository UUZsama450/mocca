# UIKit live whole-page motion experiment (5021)

Base: committed 5020 (`29a666fabce1b611ead97639a8a2cfc93ab8da11`), installed on the iPhone 17 Pro before this experiment. The exact signed 5020 package remains in its candidate verification directory for rollback.

## One-variable boundary

Move the right live panel with a persistent public `UIHostingController` and `UIView.transform`. The existing Root gesture intent, cancellation, spring/display-link sampling, semantic close timing, conversation-ready acknowledgement, sidebar parallax, scrim, continuous leading corners and shadow code remain unchanged. This does not add a screenshot, replace message renderers, change the 12-message entry window, replace gesture recognizers, or expand the existing 5019 viewport-refresh deferral.

`DrawerPresentationProgressTracker` forwards its existing progress samples to a weak live-panel receiver. UIKit moves the complete existing view; the hosted chat root is created once and is never replaced during motion. Geometry is changed only on a real size/inset change. Existing chrome reads progress in its own SwiftUI leaf. Normal AppModel observation, streaming display policy, navigation and concrete-tail readiness remain live. Callback storage is refreshed without invalidating content. Root-supplied keyboard/container insets are consumed once. The stationary wrapper returns no hit outside the translated child, allowing the exposed drawer to receive the first tap.

The candidate uses UIKit on ordinary launch. `-disableDrawerLiveUIKitPanel` selects the 5020 SwiftUI movement for a controlled A/B run at process launch; it never swaps hosts during a chat. No settings migration or persisted feature flag is introduced.

## Validation

`/usr/bin/python3 CandidateTests/check_live_uikit_panel.py` verifies 25 unchanged source contracts and executes 52 extracted settle scenarios across 5020 and 5021. These cover drag/button/conversation-ready close, rapid reversal, cancellation, old completion and disappearance with controlled time/observation/UIKit receivers. They do not prove device frames or actual touch recognition.

`CandidateTests/LivePanelUITests.swift` tests the actual simulator app through both launch routes using generated fixtures. Acceptance: A→B→A identity and actual tail; same-conversation reentry; exposed sidebar row and scrim first tap; horizontal drag open/close; empty chat; keyboard/tail/header geometry. Screenshots must be inspected after test completion.

Current runtime/build results are recorded under `work/verification/drawer-live-uikit-panel/`. iPhone 17 Pro smoothness and fingers-on-device comparison remain pending until actually observed. A successful simulator/build result must not be described as a measured speedup.

## Completed checks (2026-09-13)

Simulator Debug build passed. All six baseline/native scenario variants passed across UI-01 (two entry/drawer cases) and UI-02 (four corrected keyboard/empty cases). UI-01 also had four test-harness failures: its old `TextField` query did not match the current `ComposerInputTextView`, and the first synthetic drag started over selectable text. UI-02 targets the real composer's label and uses the empty page for the horizontal gesture. No product change was needed between the two runs.

Screenshot inspection found matching open-panel chrome and closed transcript geometry. Closed header frame was `(16, 70, 50, 50)` on both routes; composer frame was `(26, 749, 350, 21)` with keyboard down and `(26, 447, 350, 21)` with it up. Native opening places the header at x=329.56; SwiftUI rounds this to x=329.667 (less than one simulator pixel). The receiver also passed eight weak ownership/attach/detach/clamping checks. No device frame-time or performance improvement is claimed.

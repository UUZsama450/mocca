# 5028 — branch bookmarks, reaction picker, haptics

Candidate: `codex/reaction-haptics-bookmarks-5028`, based on the device-accepted 5027 commit `5fd09383b62c31108f46030ef4709d4202ceb06a`.

## Behavior

- A new branch copies only the selected reply path through the chosen message. It clears `bookmarkedAt` on the new message values; the originals, emoji reactions, reaction author, attachments, and other content retain their existing behavior. Existing duplicate bookmarks are not migrated or removed.
- The assistant blank-area reaction strip owns its entrance and dismissal state in a small leaf overlay. Entrance uses a 0.30 s spring with damping 0.78, opacity and a 6 pt offset; dismissal uses 0.14 s ease-out. Reduce Motion removes scaling/translation and retains a short fade. Duplicate dismissal is gated, and delayed callbacks check presentation identity.
- The strip uses one native regular Liquid Glass effect on iOS 26+, with the material fallback on older systems. The user's native message menu remains unchanged.
- Fresh preferences enable global, switch, drawer, card, and generation haptics, with list-item haptics disabled. Saved choices and the old missing-field decoder fallbacks are retained.
- Turning global haptics off disables the five child controls without replacing their stored values. Re-enabling global haptics restores their availability.
- A short tap on the new-chat header emits the existing selection feedback only if the selected conversation ID changes. Allocating a draft and reusing another empty draft both qualify; the current empty draft and a persistence-rejected operation do not. Feedback uses the existing global guard, independently of scene switches. The shared long-press action and group creator are unchanged.

## Performance boundaries

The positioning `GeometryReader` and glass view exist only while a reaction picker is presented. Animation state does not live in `ChatView` and does not animate message mutations. No display link, repeating timer, polling task, or extra transcript-wide geometry reader was added. The 5027 drawer ownership, content effect, scroll, and keyboard code is unchanged. These boundaries do not establish a phone FPS result or zero rendering cost while glass is visible.

## Verification

- `InteractionPolishTests.swift`: hosted XCTest against the actual app model. Confirms branch originals stay equal, selected versions flatten correctly, fresh IDs/reactions/author survive, and a repeated branch creates no extra bookmarks. Confirms current-empty no-op vs another-empty reuse. Confirms new defaults, all 64 saved haptic combinations, and legacy decoder fallback. 3 tests passed.
- `check_new_chat_haptic.py`: executes the extracted production header actions and production global guard with controlled model outcomes and UIKit receivers. Six event-count cases passed. This validates dispatch, not physical motor feel.
- `check_reaction_picker_runtime.py`: executes extracted production SwiftUI views on the task-owned iOS simulator. Normal and Reduce Motion inputs both pass normal close, immediate duplicate close, More completion, and stale-close/new-presentation identity checks. The environment input and action drivers are test-only; no product hooks were added.
- Actual intermediate rendered screenshots show the smaller/faded entrance and settled native glass. Snapshot rendering itself blocks the simulator main thread, so captures were separated from lifecycle checks after diagnosing contaminated initial timing runs. These screenshots are appearance evidence, not frame-time measurements.
- Actual app UI checks passed: assistant blank-area long press, dismissal, reaction selection, More sheet, unchanged header long-press menu, repeated empty-chat taps, global haptic disabling/restoration, keyboard layout, and repeated partial/full drawer drags. Four test methods passed across the initial UI result and the corrected haptic control result. The settings driver was corrected to wait for drawer settlement, scroll lazy rows into view, and tap the actual switch control instead of its row label.
- Signed-device deployment is recorded separately in the local deployment receipt after completion.

Local evidence: `work/verification/interaction-polish/` and `work/verification/device-5028/`. Only generated fixture data is used on the disposable simulator. The authorized phone install uses the existing migration Bundle ID and preserves its data container; no uninstall, restore, or new chat-data backup is part of this batch.

# Drawer unread reply indicator isolation

Baseline: installed 5053, commit `021859bc9ffa84800b9e2d7fbde28f97a5c5d445`.
Candidate: `codex/drawer-unread-leaf`, `work/candidates/mocca-drawer-unread-leaf-a`.

The list previously read the entire unread set in `ConversationDrawerContent.body`, passed a Boolean to normal/search rows, and included that Boolean in each row's identity. Unread changes could invalidate list evaluation and recreate a changed row.

The existing 5-point accent-colored circle now reads the set inside `DrawerUnreadReplyIndicator`. Normal, date-grouped, group-chat and content-search paths construct this leaf with conversation ID and selection state. Unread state is removed from both row identity forms; selection and normal-row title identity remain intact. The selected row suppresses its dot without observing the unread set. The model's unread marking/clearing and persistence are unchanged.

The unread set remains shared: other mounted unselected dot leaves may evaluate on an unrelated unread update. This change removes the list/title dependency, not every dot notification. Selection, titles, conversation ordering and preferences may still legitimately update the list. Removing one dependency is not a measured FPS increase.

Validation script: `CandidateTests/check_drawer_unread_leaf.py <output-directory>`.

- Extracts the actual production leaf. Explicit Observation tests replace only environment injection with a supplied model; rendered comparisons keep the actual environment property.
- Construction fixture: 20 unread changes notify the old parent 20 times, candidate parent 0, unselected leaf 20, selected leaf 0. The fixture is not the complete iOS drawer hierarchy.
- Native macOS SwiftUI ImageRenderer compares the old/new indicator in title-row HStacks with both production spacings, selected/unselected and read/unread: 8 pixel-identical pairs.
- Source checks cover both leaf call sites, all three row call paths through compilation, retained selection/title identity, and unchanged drawer motion, grouping, selection handlers, model, message rendering and persistence files.
- Full generic iOS Debug build recorded separately under `work/verification/drawer-unread-leaf-20260919/build.log`.

No phone installation or frame-time measurement is part of this change. Phone remains on 5053 until a subsequent deployment.

Result: all isolation and 8 render-pair checks PASS. Full generic iOS Debug build succeeded with signing disabled. No iPhone installation or FPS claim. Existing UITextItemInteraction deprecation warning is outside the changed file.

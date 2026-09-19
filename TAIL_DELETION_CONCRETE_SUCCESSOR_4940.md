# Mocca 4940

Baseline: full 4938 candidate. The rejected 4939 content-mutation experiment is not included.

Scope:

- Keep the existing message-deletion landing task as the single scroll owner.
- Only when deleting the final assistant message while slightly off the latest bottom, temporarily render that message and its immediate user predecessor as a bounded concrete tail.
- Delete only after the predecessor is concrete, then require the same predecessor and bottom sentinel from the post-deletion revision before restoring the captured bottom distance.
- Release the temporary concrete tail after a visible landing; cancel it on touch, drawer presentation, conversation/session change, or view disappearance.

Unchanged paths: ordinary message deletion, exact-bottom deletion, code-block expansion/collapse, table layout, streaming follow, keyboard positioning, message navigation, and drawer animation ownership.

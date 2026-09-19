# 5049: system-scheduled drawer refresh experiment

Base: original 5047, commit 34b9de8. Branch: codex/drawer-system-refresh-5049. No 5048 native-chrome changes.

Default launch skips the dedicated drag high-refresh lease and leaves the settle and optional trace display links at their default frame-rate preferences. No global ProMotion configuration is changed. This does not enforce 60 fps. Launch argument `-enableDrawerHighRefresh` restores all three original 80-120/preferred-120 request sites for a controlled comparison.

User subsequently requested a faster settle in the same trial. Spring response is now 0.34 instead of 0.42; damping remains 0.92. The settle cutoff scales proportionally to 0.560 * (0.34 / 0.42), approximately 0.4533 seconds. Elapsed-time sampling, held-finger tracking, gesture arbitration, touch routing, transcript and chrome are unchanged. Removing the refresh gates AND restoring these two timing constants restores RootView byte-for-byte to 5047. App and extension are both 5049.

User authorized installation for a day of physical interaction testing. Test with Low Power Mode and Accessibility Limit Frame Rate off to assess default scheduling. Compare held drag, release settle, interrupted reversal, long-content chats and keyboard. Stable 60 may feel good, but neither frame rate nor improved performance is claimed without measurement. This is now a combined refresh-and-timing trial; subjective differences cannot be attributed solely to refresh policy. The enableDrawerHighRefresh flag restores refresh requests only, not the original timing.

No uninstall, data clearing or chat backup is part of this update. Original signed 5047 rollback artifact remains at its original candidate ReleaseDerivedData. Build and deployment evidence goes in work/verification/drawer-system-refresh-5049.

## Deployment verification

Signed Release build succeeded. Main app and extension verified arm64, strict signatures and matching dSYM UUIDs. Installed in place and launched on iPhone 17 Pro; app readback confirms test bundle 5049, production remains 5029. Process readback recorded under work/verification/drawer-system-refresh-5049. No uninstall, data clear or chat-store snapshot performed; byte-identical data preservation was not measured. Physical interaction acceptance and FPS remain pending user trial. Real SwiftUI spring test confirms the same time-normalized trajectory (maximum difference 2.22e-16); this is math verification, not perceived smoothness.

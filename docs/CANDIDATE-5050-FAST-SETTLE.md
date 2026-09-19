# 5050: original high refresh with faster drawer settle

User preferred 5049 launched with -enableDrawerHighRefresh and requested a permanent compiled default. Based on 5047 product behavior with only two RootView constants changed: spring response .42 -> .34, cutoff .560 -> .560*(.34/.42). Original three high-refresh request sites are restored exactly; no experiment flag is required. No 5048 native-chrome changes. Damping .92 and held drag are unchanged. Same normalized spring trajectory was verified in 5049. User subjective acceptance of the combination is positive; no measured FPS claim.

Main and extension build 5050. Physical install authorized. Same-bundle overwrite; no uninstall, data clear or chat-store copies.

Signed Release build, strict signatures, arm64 and both dSYM UUID matches verified. Installed in place on iPhone 17 Pro and launched without experimental arguments. Readback confirms test build 5050; production remains 5029. Main and extension processes observed. No data clearing, uninstall or chat-store snapshot. Build/install proof is separate from physical behavior acceptance.

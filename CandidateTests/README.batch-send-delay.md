# Batched sending and reply segmentation checks

`UserBatchTests.swift` exercises durable batches, cancellation, legacy preference decoding, the configurable 3–15 second delay, per-send deadline capture, backup round trips and request ownership. The new delay tests use the actual timer and synthetic captured requests; they do not contact a model provider.

Create a disposable host with `python3 CandidateTests/prepare_user_batch_host.py work/batch-delay-host`. Build and test its `Slice1Validation` scheme on a dedicated iOS simulator, overriding `MOCCA_BUNDLE_IDENTIFIER=com.mocca.lab.replysegments` for this portable project. Select `Slice1UITests/UserBatchTests` and `Slice1UITests/ReplySegmentationTests`. Never run this fixture against a real app data container.

`UserBatchUITests.testDelaySliderPersistsAndDrawerArrowsMatch` covers the settings slider endpoints, default, retained value, relaunch persistence, and the two drawer disclosures. It requires the disposable debug host with the local reading fixture. Captured UI frames complement assertions; these checks do not measure phone energy or frame pacing.

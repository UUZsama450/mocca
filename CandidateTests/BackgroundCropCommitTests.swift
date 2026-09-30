@MainActor final class BackgroundCropCommitTests: XCTestCase {
    private func image() -> UIImage {
        let f=UIGraphicsImageRendererFormat();f.scale=1
        return UIGraphicsImageRenderer(size:CGSize(width:30,height:60),format:f).image { ctx in
            UIColor.green.setFill();ctx.fill(CGRect(x:0,y:0,width:30,height:60))
        }
    }
    private func files() -> Set<String> {
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!.appendingPathComponent("AssistantMedia")
        return Set((try? FileManager.default.contentsOfDirectory(atPath:root.path)) ?? [])
    }
    func testSidebarPreferenceFailureLeavesOriginalAndRemovesUncommittedFile() async throws {
        let image=image()
        let old=try XCTUnwrap(AssistantMediaStore.saveSidebarBackground(image))
        defer { AssistantMediaStore.remove(old);AppPreferences.allowSave=true }
        let harness=SidebarCommitHarness(old:old,image:image)
        let before=files();AppPreferences.allowSave=false
        let result=await harness.saveCroppedSidebarBackground(image,requestID:harness.pendingSidebarBackgroundCrop!.id)
        XCTAssertFalse(result)
        XCTAssertEqual(harness.model.preferences.sidebarBackground,old)
        XCTAssertTrue(AssistantMediaStore.hasImage(for:old))
        XCTAssertEqual(files(),before)
    }
    func testSidebarSuccessCommitsBeforeRemovingOldAndKeepsNewerVisibilityChoice() async throws {
        let image=image()
        let old=try XCTUnwrap(AssistantMediaStore.saveSidebarBackground(image))
        let harness=SidebarCommitHarness(old:old,image:image)
        harness.sidebarBackgroundVisibilitySequence=2
        let result=await harness.saveCroppedSidebarBackground(image,requestID:harness.pendingSidebarBackgroundCrop!.id)
        let new=try XCTUnwrap(harness.model.preferences.sidebarBackground)
        defer { AssistantMediaStore.remove(old);AssistantMediaStore.remove(new) }
        XCTAssertTrue(result);XCTAssertNotEqual(new,old)
        XCTAssertFalse(AssistantMediaStore.hasImage(for:old));XCTAssertTrue(AssistantMediaStore.hasImage(for:new))
        XCTAssertFalse(harness.model.preferences.sidebarBackgroundEnabled)
        XCTAssertEqual(AppPreferences.saved,harness.model.preferences)
    }
    func testCancelledSidebarRequestCannotOverwriteAndLeavesNoOrphanFile() async throws {
        let image=image()
        let old=try XCTUnwrap(AssistantMediaStore.saveSidebarBackground(image))
        defer { AssistantMediaStore.remove(old);CropSaveGate.release() }
        let harness=SidebarCommitHarness(old:old,image:image)
        let requestID=harness.pendingSidebarBackgroundCrop!.id
        let before=files();CropSaveGate.shouldPause=true
        let save=Task { await harness.saveCroppedSidebarBackground(image,requestID:requestID) }
        for _ in 0..<100 where CropSaveGate.continuation == nil { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertNotNil(CropSaveGate.continuation)
        harness.pendingSidebarBackgroundCrop=nil
        CropSaveGate.release()
        let result=await save.value
        XCTAssertFalse(result);XCTAssertEqual(harness.model.preferences.sidebarBackground,old)
        XCTAssertEqual(files(),before)
    }
    func testAssistantCropKeepsOriginalUntilParentSaveAndReplacesOnlyTemporaryMedia() async throws {
        let image=image(),owner=UUID()
        let old=try XCTUnwrap(AssistantMediaStore.saveBackground(image,assistantID:owner))
        let harness=AssistantCommitHarness(owner:owner,old:old,image:image)
        let first=await harness.saveCroppedBackground(image,requestID:harness.pendingBackgroundCrop!.id)
        let temporary=try XCTUnwrap(harness.profile.background)
        XCTAssertTrue(first);XCTAssertTrue(AssistantMediaStore.hasImage(for:old))
        harness.pendingBackgroundCrop=BackgroundCropRequest(image:image)
        let second=await harness.saveCroppedBackground(image,requestID:harness.pendingBackgroundCrop!.id)
        let final=try XCTUnwrap(harness.profile.background)
        defer { AssistantMediaStore.remove(old);AssistantMediaStore.remove(temporary);AssistantMediaStore.remove(final) }
        XCTAssertTrue(second);XCTAssertNotEqual(final,temporary)
        XCTAssertFalse(AssistantMediaStore.hasImage(for:temporary))
        XCTAssertTrue(AssistantMediaStore.hasImage(for:old));XCTAssertTrue(AssistantMediaStore.hasImage(for:final))
    }
    func testClosedAssistantEditorRejectsLateCropAndCleansItsNewFile() async throws {
        let image=image(),owner=UUID()
        let old=try XCTUnwrap(AssistantMediaStore.saveBackground(image,assistantID:owner))
        defer { AssistantMediaStore.remove(old);CropSaveGate.release() }
        let harness=AssistantCommitHarness(owner:owner,old:old,image:image)
        let requestID=harness.pendingBackgroundCrop!.id,before=files()
        CropSaveGate.shouldPause=true
        let save=Task { await harness.saveCroppedBackground(image,requestID:requestID) }
        for _ in 0..<100 where CropSaveGate.continuation == nil { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertNotNil(CropSaveGate.continuation)
        harness.editorIsActive=false
        CropSaveGate.release()
        let result=await save.value
        XCTAssertFalse(result);XCTAssertEqual(harness.profile.background,old)
        XCTAssertEqual(files(),before)
    }
}

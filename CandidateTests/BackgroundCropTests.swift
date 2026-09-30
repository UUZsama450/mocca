import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import Mocca

@MainActor final class BackgroundCropTests: XCTestCase {
    private func image(_ size: CGSize = CGSize(width: 1000, height: 800)) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size:size,format:format).image { context in
            UIColor.red.setFill();context.fill(CGRect(origin:.zero,size:size))
            UIColor.blue.setFill();context.fill(CGRect(x:size.width/2,y:0,width:size.width/2,height:size.height))
        }
    }
    private func canvas(_ image:UIImage, destination:BackgroundCropDestination) -> (UIWindow,BackgroundCropCanvas) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window=UIWindow(windowScene:scene)
        window.frame=CGRect(x:0,y:0,width:402,height:874)
        let root=UIViewController();window.rootViewController=root;window.isHidden=false
        root.view.frame=window.bounds
        let canvas=BackgroundCropCanvas(image:image,destination:destination)
        canvas.frame=CGRect(x:20,y:100,width:window.bounds.width-40,height:window.bounds.height-180)
        root.view.addSubview(canvas);canvas.setNeedsLayout();canvas.layoutIfNeeded()
        addTeardownBlock { @MainActor in window.isHidden=true }
        return (window,canvas)
    }
    private func assertValid(_ canvas:BackgroundCropCanvas, image:UIImage, aspect:CGFloat) throws {
        let r=try XCTUnwrap(canvas.selectedImageRect)
        XCTAssertGreaterThan(r.width,0);XCTAssertGreaterThan(r.height,0)
        XCTAssertGreaterThanOrEqual(r.minX,-0.01);XCTAssertGreaterThanOrEqual(r.minY,-0.01)
        XCTAssertLessThanOrEqual(r.maxX,image.size.width+0.01);XCTAssertLessThanOrEqual(r.maxY,image.size.height+0.01)
        XCTAssertEqual(r.width/r.height,aspect,accuracy:0.001)
    }
    func testDestinationRatiosMatchPhoneAndCappedSidebarSurface() {
        XCTAssertEqual(BackgroundCropDestination.sidebar.aspectRatio(windowSize:CGSize(width:402,height:874)),(402*0.78+44)/874,accuracy:0.00001)
        XCTAssertEqual(BackgroundCropDestination.sidebar.aspectRatio(windowSize:CGSize(width:1024,height:1366)),434/1366,accuracy:0.00001)
        XCTAssertEqual(BackgroundCropDestination.assistant(UUID()).aspectRatio(windowSize:CGSize(width:402,height:874)),402/874,accuracy:0.00001)
    }
    func testNativeViewportCoversWideTallAndSquareSourcesAtZoomAndEdges() throws {
        for size in [CGSize(width:1600,height:600),CGSize(width:600,height:1800),CGSize(width:800,height:800)] {
            let image=image(size)
            for destination in [BackgroundCropDestination.sidebar,.assistant(UUID())] {
                let (window,c)=canvas(image,destination:destination)
                let aspect=destination.aspectRatio(windowSize:window.bounds.size)
                try assertValid(c,image:image,aspect:aspect)
                let initial=try XCTUnwrap(c.selectedImageRect)
                // UIScrollView rounds offsets to physical pixels.
                let pixelTolerance = 1 / (window.screen.scale * c.scrollView.zoomScale) + 0.01
                XCTAssertEqual(initial.midX,image.size.width/2,accuracy:pixelTolerance)
                XCTAssertEqual(initial.midY,image.size.height/2,accuracy:pixelTolerance)
                c.scrollView.setZoomScale(c.scrollView.minimumZoomScale*3,animated:false)
                for point in [CGPoint.zero,CGPoint(x:c.scrollView.contentSize.width-c.scrollView.bounds.width,y:c.scrollView.contentSize.height-c.scrollView.bounds.height)] {
                    c.scrollView.contentOffset=point
                    try assertValid(c,image:image,aspect:aspect)
                }
                c.resetCrop()
                let reset=try XCTUnwrap(c.selectedImageRect)
                XCTAssertEqual(reset.minX,initial.minX,accuracy:0.1)
                XCTAssertEqual(reset.width,initial.width,accuracy:0.1)
                XCTAssertEqual(reset.minY,initial.minY,accuracy:0.1)
                window.isHidden=true
            }
        }
    }
    func testResizePreservesCenterAndRelativeZoom() throws {
        let image=image(CGSize(width:1600,height:1600))
        let (window,c)=canvas(image,destination:.assistant(UUID()))
        c.scrollView.setZoomScale(c.scrollView.minimumZoomScale*2,animated:false)
        c.scrollView.contentOffset=CGPoint(x:(c.scrollView.contentSize.width-c.scrollView.bounds.width)/2,y:(c.scrollView.contentSize.height-c.scrollView.bounds.height)/2)
        let before=try XCTUnwrap(c.selectedImageRect)
        window.bounds=CGRect(x:0,y:0,width:874,height:402)
        c.frame=CGRect(x:20,y:60,width:834,height:300);c.setNeedsLayout();c.layoutIfNeeded()
        let after=try XCTUnwrap(c.selectedImageRect)
        XCTAssertEqual(before.midX,after.midX,accuracy:1)
        XCTAssertEqual(before.midY,after.midY,accuracy:1)
        XCTAssertEqual(c.scrollView.zoomScale/c.scrollView.minimumZoomScale,2,accuracy:0.01)
        try assertValid(c,image:image,aspect:BackgroundCropDestination.assistant(UUID()).aspectRatio(windowSize:window.bounds.size))
    }
    func testDecodeRejectsInvalidDataAndBoundsLargeImages() async throws {
        let invalid = await BackgroundCropImageIO.prepare(Data("not an image".utf8))
        XCTAssertNil(invalid)
        let source=image(CGSize(width:5120,height:1280))
        let decoded=await BackgroundCropImageIO.prepare(try XCTUnwrap(source.jpegData(compressionQuality:0.8)))
        let result=try XCTUnwrap(decoded)
        XCTAssertEqual(max(result.size.width,result.size.height),4096)
        XCTAssertEqual(result.imageOrientation,.up)
    }
    func testEXIFRotationIsAppliedBeforeCropping() async throws {
        let source=image(CGSize(width:80,height:40))
        let data=NSMutableData()
        let destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,try XCTUnwrap(source.cgImage),[kCGImagePropertyOrientation:6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let decoded=await BackgroundCropImageIO.prepare(data as Data)
        let result=try XCTUnwrap(decoded)
        XCTAssertEqual(result.size,CGSize(width:40,height:80))
        XCTAssertEqual(result.imageOrientation,.up)
    }
    func testCropRetainsSelectedColorAndCapsOutputPixels() async throws {
        let source=image(CGSize(width:3000,height:3000))
        let cropped=await BackgroundCropImageIO.crop(source,rect:CGRect(x:1800,y:0,width:1200,height:3000))
        let result=try XCTUnwrap(cropped)
        XCTAssertEqual(result.scale,1);XCTAssertEqual(result.size.height,2048)
        XCTAssertEqual(result.size.width/result.size.height,0.4,accuracy:0.001)
        var pixel=[UInt8](repeating:0,count:4)
        let context=try XCTUnwrap(CGContext(data:&pixel,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try XCTUnwrap(result.cgImage),in:CGRect(x:0,y:0,width:1,height:1))
        XCTAssertGreaterThan(pixel[2],230);XCTAssertLessThan(pixel[0],25)
    }
    func testInvalidCropCannotProduceAReplacement() async {
        let source=image()
        let result=await BackgroundCropImageIO.crop(source,rect:CGRect(x:3000,y:3000,width:100,height:100))
        XCTAssertNil(result)
    }
    func testBothDestinationsWriteDistinctStandardMediaReferences() async throws {
        let source=image()
        let owner=UUID()
        let side=await BackgroundCropImageIO.save(source,destination:.sidebar)
        let chat=await BackgroundCropImageIO.save(source,destination:.assistant(owner))
        let a=try XCTUnwrap(side),b=try XCTUnwrap(chat)
        defer { AssistantMediaStore.remove(a);AssistantMediaStore.remove(b) }
        XCTAssertNotEqual(a,b)
        XCTAssertTrue(a.hasPrefix("file:sidebar-background-"))
        XCTAssertTrue(b.hasPrefix("file:"+owner.uuidString+"-background-"))
        XCTAssertTrue(AssistantMediaStore.hasImage(for:a));XCTAssertTrue(AssistantMediaStore.hasImage(for:b))
    }
    func testEditorSheetDoesNotDisappearItsSettingsParent() async throws {
        let state=SheetState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window=UIWindow(windowScene:scene)
        window.frame=scene.coordinateSpace.bounds
        let host=UIHostingController(rootView:SheetParent(state:state,image:image()))
        window.rootViewController=host;window.makeKeyAndVisible()
        defer { window.isHidden=true }
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertTrue(state.parentActive)
        state.presented=true
        try await Task.sleep(for:.seconds(2))
        XCTAssertTrue(state.parentActive)
        XCTAssertNotNil(host.presentedViewController)
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "Background crop editor"
        attachment.lifetime = .keepAlways
        add(attachment)
        state.presented=false
        try await Task.sleep(for:.milliseconds(400))
        XCTAssertTrue(state.parentActive)
        XCTAssertEqual(state.saves,0)
    }
}
@MainActor @Observable private final class SheetState { var presented=false;var parentActive=false;var saves=0 }
private struct SheetParent: View {
    @Bindable var state:SheetState
    let image:UIImage
    var body:some View {
        Text("settings fixture")
            .onAppear { state.parentActive=true }
            .onDisappear { state.parentActive=false }
            .sheet(isPresented:$state.presented) {
                BackgroundImageCropEditor(image:image,destination:.sidebar) { _ in state.saves += 1;return true }
            }
    }
}

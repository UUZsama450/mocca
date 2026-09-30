"""Render source-extracted sidebar layout; no product hooks or user images."""
from pathlib import Path
import subprocess, json
root = Path(__file__).resolve().parents[1]
out = root/'work/sidebar-mask-validation'
out.mkdir(parents=True, exist_ok=True)
source = (root/'Mocca/RootView.swift').read_text()
view_start = source.index('private struct SidebarBackgroundView:')
view_end = source.index('private struct ConversationDrawer:', view_start)
view = source[view_start:view_end]
geometry = view[view.index('        GeometryReader { proxy in'):view.index('        .task(id: loadRequest)')]
assert geometry.count('.frame(width: size.width, height: size.height, alignment: .topLeading)') == 1
mac_geometry = geometry.replace('Image(uiImage: backgroundImage)', 'Image(nsImage: backgroundImage)')
old_geometry = mac_geometry.replace('.frame(width: size.width, height: size.height, alignment: .topLeading)', '.frame(width: size.width, height: size.height)')
load_request = source[source.index('private struct SidebarBackgroundLoadRequest:'):view_start]
stubs = '''import SwiftUI
import UIKit
import Observation
struct UserPreferences {
    var sidebarBackgroundEnabled = true
    var sidebarBackground: String? = nil
    var sidebarBackgroundOpacity = 0.0
    static func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double { Swift.min(Swift.max(value, lower), upper) }
}
@Observable final class AppModel {
    var preferences = UserPreferences()
    var themeSurfaceUIColor: UIColor = .white
}
enum AssistantMediaStore {
    static func image(for reference: String?) -> UIImage? { nil }
}
'''
(out/'SidebarIOS.swift').write_text(stubs + load_request + view)
sdk = subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
subprocess.run(['xcrun','swiftc','-typecheck','-swift-version','5','-sdk',sdk,'-target','x86_64-apple-ios17.0-simulator',str(out/'SidebarIOS.swift')],check=True)
header = '''import SwiftUI
import AppKit
struct Request { let isEnabled: Bool }
'''
def probe(name, code):
    return f'''struct {name}: View {{
    let referenceWidth: CGFloat
    let backgroundImage: NSImage?
    let loadRequest: Request
    let strength: Double
    let dark: Bool
    var body: some View {{
        let surface = dark ? Color.black : Color.white
        let topOpacity = 0.40 * strength
        let bottomOpacity = strength
{code}
    }}
}}
'''
runner = r'''
@main struct Check {
    @MainActor static func main() throws {
        let sizes: [(CGFloat, CGFloat)] = [(358,874),(434,874),(358,400)]
        let sources: [(CGFloat, CGFloat)] = [(960,1440),(1600,600),(600,2200),(358,874)]
        var cases = 0
        func render<V: View>(_ content: V) -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: renderer.cgImage!)
        }
        func channel(_ b: NSBitmapImageRep, _ x: Int, _ y: Int, _ dark: Bool) -> Double {
            let c = b.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            return Double(dark ? c.redComponent : c.greenComponent)
        }
        func verify(_ b: NSBitmapImageRep, dark: Bool, gradient: Bool) {
            let w=b.pixelsWide, h=b.pixelsHigh
            for y in [2,h/4,h/2,h-3] {
                let reference=channel(b,2,y,dark)
                for x in [w/4,w/2,w*3/4,w-3] {
                    precondition(abs(reference-channel(b,x,y,dark)) < 0.012, "Uncovered band x=\(x),y=\(y),dark=\(dark)")
                }
            }
            if gradient {
                let top=channel(b,w/2,2,dark), bottom=channel(b,w/2,h-3,dark)
                precondition(dark ? top > bottom + 0.05 : bottom > top + 0.05, "Vertical gradient misplaced")
            }
        }
        for (width,height) in sizes {
            for (iw,ih) in sources {
                let image=NSImage(size: NSSize(width:iw,height:ih),flipped:false) { rect in
                    NSColor.red.setFill();rect.fill();return true
                }
                for strength in [0.0,0.5,1.0] {
                    for dark in [false,true] {
                        let b=render(Fixed(referenceWidth:width,backgroundImage:image,loadRequest:Request(isEnabled:true),strength:strength,dark:dark).frame(height:height))
                        precondition(b.pixelsWide==Int(width) && b.pixelsHigh==Int(height))
                        verify(b,dark:dark,gradient:strength>0)
                        cases += 1
                    }
                }
            }
            for dark in [false,true] {
                for enabled in [false,true] {
                    let b=render(Fixed(referenceWidth:width,backgroundImage:nil,loadRequest:Request(isEnabled:enabled),strength:1,dark:dark).frame(height:height))
                    verify(b,dark:dark,gradient:false)
                    let c=channel(b,Int(width)-3,Int(height)-3,dark)
                    precondition(abs(c-(dark ? 0:1))<0.012)
                    cases += 1
                }
            }
        }
        let image=NSImage(size:NSSize(width:960,height:1440),flipped:false) { rect in
            NSColor.red.setFill();rect.fill();return true
        }
        let old=render(Baseline(referenceWidth:358,backgroundImage:image,loadRequest:Request(isEnabled:true),strength:1,dark:false).frame(height:874))
        let fixed=render(Fixed(referenceWidth:358,backgroundImage:image,loadRequest:Request(isEnabled:true),strength:1,dark:false).frame(height:874))
        let oldGap=abs(channel(old,100,700,false)-channel(old,350,700,false))
        let fixedGap=abs(channel(fixed,100,700,false)-channel(fixed,350,700,false))
        precondition(oldGap>0.5 && fixedGap<0.012, "Regression control must detect the old band")
        for (name,b) in [("before",old),("after",fixed)] {
            try b.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"work/sidebar-mask-validation/\(name).png"))
        }
        let receipt: [String:Any] = ["render_cases_passed":cases,"baseline_band_detected":true,"old_horizontal_channel_difference":oldGap,"fixed_horizontal_channel_difference":fixedGap,"ios_view_typecheck_passed":true,"phone_fps_measured":false,"renderer":"macOS SwiftUI ImageRenderer; source geometry, NSImage adapter, synthetic solid image"]
        let data=try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:URL(fileURLWithPath:"work/sidebar-mask-validation/results.json"))
        print(String(decoding:data,as:UTF8.self))
    }
}
'''
(out/'Render.swift').write_text(header+probe('Fixed',mac_geometry)+probe('Baseline',old_geometry)+runner)
subprocess.run(['xcrun','swiftc','-parse-as-library',str(out/'Render.swift'),'-o',str(out/'render')],check=True)
subprocess.run([str(out/'render')],cwd=root,check=True)

@main final class Delegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w=UIWindow(frame:UIScreen.main.bounds);w.rootViewController=UIViewController();w.makeKeyAndVisible();window=w
        Task { @MainActor in run() };return true
    }
    @MainActor func run() {
        let baseline=Baseline(),candidate=Candidate()
        var failures:[[String:Any]]=[];var comparisons=0;var timings:[[String:Any]]=[]
        var samples:[String]=[
            "", "x", "let x = 1", "\n", "\n\n", "\nhello", "hello\n\n", "hello\r", "a\r\nb\r\n", "\r\n\r\n",
            "a\tb\txyz\n  hello ", " \n \n   ", "a\u{0085}b\u{000B}c\u{000C}d", "a\u{2028}b\u{2029}c\n",
            "中文 é é 🙂 👨‍👩‍👧‍👦\nمرحبا שלום\r\n第二行\u{2028}第三行\u{2029}段落",
            "\u{202E}abc\n123\u{202C}\n\u{2067}RTL שלום\u{2069}", "हिन्दी\nไทย\n日本語\n한국어", "\u{200B}\n\u{FE0F}\n\u{0301}",
            "👨🏽‍💻 🏳️‍🌈 🇨🇳\n➡︎ ➡️ ☺︎ ☺️", "let wide = \""+String(repeating:"W",count:2000)+"\"\nshort",
            (0..<32).map { "let value\($0) = \($0) // 中文 é 🙂" }.joined(separator:"\n")
        ]
        let fragments = ["", " ", "   ", " x ", "x\t", "\t", "中文🙂", "é", "\u{200B}"]
        for a in fragments { for b in fragments { for c in fragments {
            samples.append(a + "\n" + b + "\n" + c)
        } } }
        func attributed(_ text:String,_ font:CGFloat,_ spacing:CGFloat)->NSAttributedString {
            let p=NSMutableParagraphStyle();p.lineSpacing=spacing
            return NSAttributedString(string:text,attributes:[.font:UIFont.monospacedSystemFont(ofSize:font,weight:.regular),.paragraphStyle:p,.foregroundColor:UIColor.label])
        }
        let extendedOnly = ProcessInfo.processInfo.arguments.contains("-extendedOnly")
        if !extendedOnly {
        for (index,text) in samples.enumerated() {
            for font:CGFloat in [11,13,13.5,17,24,36] {
                for spacing:CGFloat in [0,3,7] {
                    let a=attributed(text,font,spacing)
                    for scale:CGFloat in [1,2,3] {
                        let old=baseline.measuredCodeSize(for:a,cacheKey:nil,displayScale:scale)
                        let new=candidate.measuredCodeSize(for:a,cacheKey:nil,displayScale:scale);comparisons+=1
                        if old != new { failures.append(["sample":index,"font":font,"spacing":spacing,"scale":scale,"old":[old.width,old.height],"new":[new.width,new.height]]) }
                    }
                }
            }
        }
        for repetition in 0..<3 {
            let a=attributed((0..<700).map { "let value\($0) = \($0) // 中文与 emoji 🙂" }.joined(separator:"\n"),13,3)
            var sizes:[CGSize]=[]
            for useNew in repetition.isMultiple(of:2) ? [false,true] : [true,false] {
                let start=CACurrentMediaTime()
                let size=useNew ? candidate.measuredCodeSize(for:a,cacheKey:nil,displayScale:3) : baseline.measuredCodeSize(for:a,cacheKey:nil,displayScale:3)
                timings.append(["repetition":repetition,"method":useNew ? "candidate":"baseline","length":a.length,"ms":(CACurrentMediaTime()-start)*1000,"size":[size.width,size.height]])
                sizes.append(size)
            }
            comparisons+=1
            if sizes[0] != sizes[1] { failures.append(["benchmarkMismatch":repetition]) }
        }
        }
        if extendedOnly {
            let lines = ["let code = 1  ", "", "   ", "中文 é 🙂", "👨‍👩‍👧‍👦", "مرحبا שלום", "\tindent\t", "\u{2028}next", "\u{2029}paragraph"]
            for font: CGFloat in [11, 13, 13.5, 17, 24, 36] {
                for count in [31, 128, 257] {
                    let text = (0..<count).map { lines[$0 % lines.count] }.joined(separator: "\n")
                    let a = attributed(text, font, 3)
                    let old = baseline.measuredCodeSize(for:a,cacheKey:nil,displayScale:3)
                    let new = candidate.measuredCodeSize(for:a,cacheKey:nil,displayScale:3)
                    comparisons += 1
                    if old != new { failures.append(["extendedFont":font,"lines":count,"old":[old.width,old.height],"new":[new.width,new.height]]) }
                }
            }
            let growing = (0..<41).map { lines[$0 % lines.count] }.joined(separator: "\n")
            for end in growing.indices {
                let a = attributed(String(growing[..<end]),13,3)
                let old = baseline.measuredCodeSize(for:a,cacheKey:nil,displayScale:3)
                let new = candidate.measuredCodeSize(for:a,cacheKey:nil,displayScale:3)
                comparisons += 1
                if old != new { failures.append(["prefixLength":a.length,"old":[old.width,old.height],"new":[new.width,new.height]]) }
            }
        }
        // Cache hits and streaming completion continue using the same pixel-rounded size.
        let a=attributed("cache\n中文🙂",13,3)
        let miss=candidate.measuredCodeSize(for:a,cacheKey:"exact-cache-test",displayScale:3)
        let hit=candidate.measuredCodeSize(for:a,cacheKey:"exact-cache-test",displayScale:3)
        comparisons+=1;if miss != hit { failures.append(["cacheMismatch":true]) }
        let result:[String:Any]=["status":failures.isEmpty ? "PASS":"FAIL","comparisons":comparisons,"failures":failures,"timings":timings]
        let url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("result.json")
        try! JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:url);exit(0)
    }
}

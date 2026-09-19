#!/usr/bin/env python3
"""Extract the production thumbnail request/cache into a Swift 6 ImageIO host.

UIKit is replaced only by an image wrapper. Test-only instrumentation observes
decoder entry/exit and joins, and gates the real ImageIO decoder deterministically.
This verifies concurrency/decoding contracts, not SwiftUI lifecycle or iPhone FPS.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT.parent / "mocca-drawer-release-scroll-gate-a"
OUT = ROOT / "work/verification/thumbnail-background-host"
PRODUCT = ROOT / "Mocca/Attachments.swift"


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


SUPPORT = r'''
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor private final class UIImage {
    enum Orientation { case up }
    let cgImage: CGImage
    let scale: CGFloat
    init(cgImage: CGImage, scale: CGFloat, orientation: Orientation) {
        self.cgImage = cgImage
        self.scale = scale
    }
}

// Only the test harness owns these synchronization and observability hooks.
private final class Probe: @unchecked Sendable {
    static let shared = Probe()
    private let lock = NSLock()
    private var events: [String: Int] = [:]
    private var waits: [(String, Int, CheckedContinuation<Void, Never>)] = []
    private var gates: [String: DispatchSemaphore] = [:]
    private var active = 0
    private var peak = 0
    private var mainThreadEntries = 0

    func event(_ name: String) {
        lock.lock()
        events[name, default: 0] += 1
        let ready = waits.filter { $0.0 == name && events[name, default: 0] >= $0.1 }
        waits.removeAll { $0.0 == name && events[name, default: 0] >= $0.1 }
        lock.unlock()
        for waiter in ready { waiter.2.resume() }
    }
    func count(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return events[name, default: 0]
    }
    private func register(_ name: String, _ count: Int, _ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        let ready = events[name, default: 0] >= count
        if !ready { waits.append((name, count, continuation)) }
        lock.unlock()
        if ready { continuation.resume() }
    }
    func wait(_ name: String, count: Int = 1) async {
        await withCheckedContinuation { register(name, count, $0) }
    }
    func block(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        precondition(gates[key] == nil)
        gates[key] = DispatchSemaphore(value: 0)
    }
    func release(_ key: String) {
        lock.lock()
        let gate = gates.removeValue(forKey: key)
        lock.unlock()
        precondition(gate != nil)
        gate?.signal()
    }
    func begin(_ key: String) {
        lock.lock()
        active += 1; peak = max(peak, active)
        if Thread.isMainThread { mainThreadEntries += 1 }
        let gate = gates[key]
        lock.unlock()
        event("start:" + key)
        if let gate { precondition(gate.wait(timeout: .now() + 10) == .success, "test decoder gate timeout") }
    }
    func end(_ key: String) {
        lock.lock(); active -= 1; lock.unlock()
        event("end:" + key)
    }
    func snapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return ["peak_concurrent_decoders": peak, "main_thread_decoder_entries": mainThreadEntries,
                "active_decoders": active, "pending_test_waiters": waits.count]
    }
}

private func writeFixture(_ url: URL, width: Int = 900, height: Int = 600, blue: Bool = false, orientation: Int = 1) {
    let space = CGColorSpaceCreateDeviceRGB()
    let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                           bytesPerRow: width * 4, space: space,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.setFillColor(CGColor(red: blue ? 0 : 1, green: 0, blue: blue ? 1 : 0, alpha: 1))
    bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = bitmap.makeImage()!
    let type = orientation == 1 ? UTType.png.identifier : UTType.jpeg.identifier
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination), "fixture encoding failed")
}

private func isBlue(_ image: CGImage) -> Bool {
    var bytes = [UInt8](repeating: 0, count: 4)
    bytes.withUnsafeMutableBytes { buffer in
        let bitmap = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                               bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return bytes[2] > bytes[0]
}
'''

RUNNER = r'''
@main private struct Tests {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let red = directory.appendingPathComponent("red.png")
        let blue = directory.appendingPathComponent("blue.png")
        let rotated = directory.appendingPathComponent("rotated.jpg")
        writeFixture(red); writeFixture(blue, blue: true); writeFixture(rotated, orientation: 6)
        var assertions: [[String: Any]] = []
        func check(_ value: Bool, _ label: String) {
            assertions.append(["name": label, "pass": value])
            precondition(value, label)
        }
        func request(_ url: URL, _ points: CGFloat) -> MessageImageThumbnailRequest {
            MessageImageThumbnailRequest(url: url, maximumPixelSize: points * 3, scale: 3)
        }
        let probe = Probe.shared
        let red38 = request(red, 38)
        let blue38 = request(blue, 38)

        // Hold the real first decode, then prove the second same-key caller joins.
        probe.block(red38.key)
        let first = Task { @MainActor in await MessageImageThumbnailCache.image(for: red38) }
        await probe.wait("start:" + red38.key)
        let second = Task { @MainActor in await MessageImageThumbnailCache.image(for: red38) }
        await probe.wait("join:" + red38.key)
        check(MessageImageThumbnailCache.testPendingCount == 1, "same key shares one pending task")
        check(probe.count("start:" + red38.key) == 1, "overlapping same-key requests decode once")

        // Different keys enqueue while the first is held, without decoding concurrently.
        probe.block(blue38.key)
        let different = Task { @MainActor in await MessageImageThumbnailCache.image(for: blue38) }
        await probe.wait("enqueue:" + blue38.key)
        check(MessageImageThumbnailCache.testPendingCount == 2, "different keys own distinct pending requests")
        check(probe.count("start:" + blue38.key) == 0, "serial decoder does not begin second key while first is held")
        probe.release(red38.key)
        let redResult = await first.value
        let redResult2 = await second.value
        await probe.wait("start:" + blue38.key)
        check(redResult != nil && redResult === redResult2, "shared callers receive identical image object")
        probe.release(blue38.key)
        let blueResult = await different.value
        check(redResult!.cgImage.width == 114 && redResult!.cgImage.height == 76, "38 points at scale 3 preserves non-square dimensions")
        check(redResult!.scale == 3 && blueResult!.scale == 3, "result wrapper preserves request scale")
        check(!isBlue(redResult!.cgImage) && isBlue(blueResult!.cgImage), "different URL keys do not exchange image pixels")
        let warm = await MessageImageThumbnailCache.image(for: red38)
        check(warm === redResult && probe.count("start:" + red38.key) == 1, "warm request returns cache without decoding")

        // Exercise actual caller cancellation publication guard from the View.
        let cancelURL = directory.appendingPathComponent("cancel.png")
        writeFixture(cancelURL)
        let cancelRequest = request(cancelURL, 112)
        probe.block(cancelRequest.key)
        let cancelled = Task { @MainActor () -> UIImage? in
            let request = cancelRequest
            /*CONSUMER*/
            return image
        }
        await probe.wait("start:" + cancelRequest.key)
        let survivor = Task { @MainActor in await MessageImageThumbnailCache.image(for: cancelRequest) }
        await probe.wait("join:" + cancelRequest.key)
        cancelled.cancel()
        probe.release(cancelRequest.key)
        let cancelledResult = await cancelled.value
        let survived = await survivor.value
        check(cancelledResult == nil && survived != nil, "one cancelled consumer does not publish or cancel the shared survivor")
        check(probe.count("start:" + cancelRequest.key) == 1, "cancellation preserves shared single decode")
        check(MessageImageThumbnailCache.cachedImage(for: cancelRequest) === survived, "shared result remains under its original cache key")
        check(survived!.cgImage.width == 336 && survived!.cgImage.height == 224, "112 points at scale 3 preserves non-square dimensions")

        let red144 = request(red, 144)
        let redLarge = await MessageImageThumbnailCache.image(for: red144)
        check(red144.key != red38.key && redLarge !== redResult, "same URL with a different pixel size has a distinct key and result")
        check(redLarge!.cgImage.width == 432 && redLarge!.cgImage.height == 288, "144 points at scale 3 preserves non-square dimensions")
        check(MessageImageThumbnailCache.cachedImage(for: red38) === redResult, "large request does not overwrite the earlier small cache entry")
        let portrait = await MessageImageThumbnailCache.image(for: request(rotated, 38))
        check(portrait!.cgImage.width == 76 && portrait!.cgImage.height == 114, "EXIF rotation is applied before thumbnail result publication")

        let badURL = directory.appendingPathComponent("repair.png")
        try Data("invalid image bytes".utf8).write(to: badURL)
        let repair = request(badURL, 38)
        let failed = await MessageImageThumbnailCache.image(for: repair)
        check(failed == nil && MessageImageThumbnailCache.testPendingCount == 0, "corrupt image returns nil and removes pending state")
        check(MessageImageThumbnailCache.cachedImage(for: repair) == nil, "failed image is not retained as a successful cache entry")
        writeFixture(badURL, blue: true)
        let repaired = await MessageImageThumbnailCache.image(for: repair)
        check(repaired != nil && isBlue(repaired!.cgImage) && probe.count("start:" + repair.key) == 2,
              "repairing the same failed path permits a fresh successful decode")
        let missing = request(directory.appendingPathComponent("missing.png"), 38)
        let missingResult = await MessageImageThumbnailCache.image(for: missing)
        check(missingResult == nil && MessageImageThumbnailCache.testPendingCount == 0, "missing file returns nil and clears pending state")

        // Already-cancelled callers never enqueue a new decode.
        let preCancelledURL = directory.appendingPathComponent("pre-cancelled.png")
        writeFixture(preCancelledURL)
        let preCancelledRequest = request(preCancelledURL, 38)
        let preCancelled = Task { @MainActor in
            await probe.wait("allow-pre-cancelled")
            return await MessageImageThumbnailCache.image(for: preCancelledRequest)
        }
        preCancelled.cancel()
        probe.event("allow-pre-cancelled")
        let preCancelledResult = await preCancelled.value
        check(preCancelledResult == nil && probe.count("enqueue:" + preCancelledRequest.key) == 0,
              "already-cancelled request exits before enqueue")

        let state = probe.snapshot()
        check(state["main_thread_decoder_entries"] == 0, "all actual ImageIO decodes entered off the main thread")
        check(state["peak_concurrent_decoders"] == 1, "distinct image decodes remained serial")
        check(state["active_decoders"] == 0 && state["pending_test_waiters"] == 0 && MessageImageThumbnailCache.testPendingCount == 0,
              "verification finishes without pending work or stranded waiters")
        let output: [String: Any] = ["status": "PASS", "assertion_count": assertions.count,
                                    "assertions": assertions, "decoder_observations": state]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
'''


def main():
    source = PRODUCT.read_text()
    baseline = (BASELINE / "Mocca/Attachments.swift").read_text()
    request = declaration(source, "private struct MessageImageThumbnailRequest: Sendable")
    cache = declaration(source, "@MainActor\nprivate enum MessageImageThumbnailCache")
    decode = declaration(source, "    nonisolated private static func decode(")
    before_image = declaration(baseline, "    static func image(for url: URL, pointSize: CGFloat)")
    old_guard = before_image[before_image.index("        guard let source"):before_image.index("\n        let image = UIImage")].strip()
    new_guard = decode[decode.index("        guard let source"):decode.index("\n        return cgImage")].strip()
    new_guard = new_guard.replace("request.url", "url").replace("request.maximumPixelSize", "maximumPixelSize")
    assert old_guard == new_guard, "ImageIO source creation/options/failure behavior changed"
    assert "maximumPixelSize: max(size * scale, size)" in source
    assert "let maximumPixelSize = max(pointSize * UIScreen.main.scale, pointSize)" in baseline
    consumer = "\n".join(source.splitlines()[source[:source.index("                let image = await MessageImageThumbnailCache.image(for: request)")].count("\n"):][:2])
    assert consumer.strip() == "let image = await MessageImageThumbnailCache.image(for: request)\n                guard !Task.isCancelled else { return }"
    consumer = consumer.replace("else { return }", "else { return nil }")
    assert "let currentResult = result?.key == request?.key ? result : nil" in source
    assert "result = Result(key: request.key, image: image)" in source

    instrumented = cache.replace(
        "if let pending = inFlight[request.key] { return await pending.value }",
        'if let pending = inFlight[request.key] { Probe.shared.event("join:" + request.key); return await pending.value }')
    instrumented = instrumented.replace("        inFlight[request.key] = pending", '        inFlight[request.key] = pending\n        Probe.shared.event("enqueue:" + request.key)')
    marker = "    nonisolated private static func decode(_ request: MessageImageThumbnailRequest) -> CGImage? {"
    instrumented = instrumented.replace(marker, marker + '\n        Probe.shared.begin(request.key)\n        defer { Probe.shared.end(request.key) }')
    instrumented = instrumented[:-1] + "    static var testPendingCount: Int { inFlight.count }\n}"
    host = SUPPORT + request + "\n" + instrumented + "\n" + RUNNER.replace("/*CONSUMER*/", consumer)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "extracted-production.swift").write_text(request + "\n" + cache + "\n")
    host_path = OUT / "ThumbnailHost.swift"
    host_path.write_text(host)
    binary = OUT / "thumbnail-host"
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    command = [compiler, "-swift-version", "6", "-parse-as-library", "-module-cache-path", str(OUT / "ModuleCache"), str(host_path), "-o", str(binary)]
    build = subprocess.run(command, text=True, capture_output=True, timeout=120)
    (OUT / "compile.log").write_text(build.stdout + build.stderr)
    if build.returncode:
        raise RuntimeError(f"Swift 6 host compilation failed: {OUT / 'compile.log'}\n{build.stderr}")
    run = subprocess.run([str(binary), str(OUT / "fixtures")], text=True, capture_output=True, timeout=40)
    (OUT / "run.log").write_text(run.stdout + run.stderr)
    if run.returncode:
        raise RuntimeError(f"Host failed: {OUT / 'run.log'}\n{run.stdout}\n{run.stderr}")
    report = json.loads(run.stdout)
    assert PRODUCT.read_text() == source, "Product source changed while the host was running"
    report.update({
        "candidate": str(ROOT), "product_source_sha256": digest(source),
        "baseline_source_sha256": digest(baseline), "extracted_source_sha256": digest(request + "\n" + cache),
        "host_sha256": digest(host), "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "compiler": subprocess.check_output([compiler, "--version"], text=True).strip(),
        "compile_command": command, "imageio_pipeline_unchanged": True,
        "consumer_guard_extracted_from_view": True, "stale_result_key_guard_present": True,
        "product_hash_unchanged_after_run": True,
        "instrumentation": ["decoder entry/exit counters and deterministic gates", "pending join/enqueue events", "read-only pending count accessor"],
        "limits": ["macOS ImageIO mechanism verification; UIKit replaced only with a CGImage/scale wrapper",
                   "test-only synchronization cannot measure normal performance",
                   "SwiftUI task delivery, UIImage display and physical iPhone interaction remain unverified"],
    })
    (OUT / "summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "assertions": report["assertion_count"], "report": str(OUT / "summary.json")}))


if __name__ == "__main__":
    main()

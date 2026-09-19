#!/usr/bin/env python3
"""Verify current ProviderViews production excerpts without accounts or an app build.

Run: /usr/bin/python3 CandidateTests/check_provider_editor_polish.py
The host harness exercises cancellation/ownership with deliberately noncooperative
fake responses; SDK typecheck validates the actual UIKit probe and SwiftUI summary.
This is not a runtime test of SwiftUI presentation, List gestures, or rendering.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Mocca/ProviderViews.swift"
OUTPUT = ROOT / "work/verification/provider-polish-5032"

STUBS = r'''
import Foundation
import Observation
struct KeyValueField: Equatable, Sendable { var name = ""; var value = "" }
enum ProviderType: Sendable { case openAI, claude, google }
struct ProviderProxySettings: Equatable, Sendable { var enabled = false }
struct ProviderAPIKey: Equatable, Sendable { var key: String; var enabled = true }
struct ProviderConfiguration: Equatable, Sendable {
 var id = UUID(); var type = ProviderType.openAI; var enabled = true; var balanceEnabled = true
 var baseURL = "https://example.invalid/v1"; var apiKey = "test"; var multiKeyEnabled = false
 var apiKeys: [ProviderAPIKey] = []; var customHeaders: [KeyValueField] = []
 var balanceAPIPath = "/credits"; var balanceResultPath = "data.balance"; var proxy = ProviderProxySettings()
 var isOpenRouter = false; var name = "Test"; var customAvatar: String?; var chatPath = "/chat/completions"; var group = ""; var models: [String] = []
 var enabledAPIKeys: [ProviderAPIKey] { apiKeys.filter { $0.enabled && !$0.key.isEmpty } }
 var hasUsableAPIKey: Bool { multiKeyEnabled ? !enabledAPIKeys.isEmpty : !apiKey.isEmpty }
}
@MainActor enum L10n {
 static func lookup(_ key:String)->String {key}
 static func format(_ key:String,_ args:[String])->String {String(format:key,arguments:args.map{$0 as CVarArg})}
}
enum AIChatService { static func fetchBalance(for provider: ProviderConfiguration) async throws -> ProviderBalanceResult { throw URLError(.unsupportedURL) } }
@MainActor enum AssistantMediaStore { static var removed: [String] = []; static func remove(_ value: String?) { if let value { removed.append(value) } } }
actor ControlledBalance {
 var requests: [Int: CheckedContinuation<ProviderBalanceResult, any Error>] = [:]; var count = 0
 func fetch(_ provider: ProviderConfiguration) async throws -> ProviderBalanceResult { count += 1; let id=count; return try await withCheckedThrowingContinuation { requests[id]=$0 } }
 func total() -> Int { count }
 func complete(_ id: Int, _ value: String) { requests.removeValue(forKey:id)?.resume(returning:.value(value)) }
 func fail(_ id: Int) { requests.removeValue(forKey:id)?.resume(throwing:URLError(.badServerResponse)) }
}
'''
DRAFT_HARNESS = r'''@MainActor final class DraftHarness {
 var configuration: ProviderConfiguration; let originalConfiguration: ProviderConfiguration; let originalAvatar: String?
 var didSave=false; var saveErrorMessage=""; var isSaveErrorPresented=false; var isLeaveConfirmationPresented=false
 var balanceQuery=ProviderBalanceQueryState(); var onSave: (ProviderConfiguration)->Bool; var dismissals=0
 init(_ p:ProviderConfiguration, onSave:@escaping (ProviderConfiguration)->Bool) { configuration=p; originalConfiguration=p; originalAvatar=p.customAvatar; self.onSave=onSave }
 func dismiss() { dismissals += 1 }
'''
TESTS = r'''@main struct Verify {
 @MainActor static func pause() async { try? await Task.sleep(for:.milliseconds(30)) }
 @MainActor static func count(_ c:ControlledBalance,_ n:Int) async { for _ in 0..<500 { if await c.total()>=n{return}; try? await Task.sleep(for:.milliseconds(2)) }; fatalError("no request") }
 @MainActor static func main() async {
  var p=ProviderConfiguration(); let c=ControlledBalance(); let v=UUID()
  let q=ProviderBalanceQueryState(debounce:.milliseconds(5),fetch:{try await c.fetch($0)})
  var bad=p; bad.balanceEnabled=false; q.show(v,provider:bad); await pause()
  bad=p; bad.apiKey=""; q.update(v,provider:bad); bad=p; bad.baseURL="invalid"; q.update(v,provider:bad); await pause()
  var n=await c.total(); precondition(n==0)
  p.enabled=false; q.update(v,provider:p); await count(c,1)
  p.apiKey="changed"; q.update(v,provider:p); await count(c,2)
  await c.complete(1,"old"); await pause(); precondition(q.result==nil && q.isFetching)
  await c.complete(2,"new"); await pause(); precondition(q.result == .value("new") && !q.isFetching)
  p.models.append("m"); p.customAvatar="avatar"; p.name="changed"; p.enabled=true; q.update(v,provider:p); await pause(); n=await c.total(); precondition(n==2)
  q.refresh(v,provider:p); await count(c,3); p.balanceAPIPath="/balance"; q.update(v,provider:p); await count(c,4)
  await c.fail(3); await pause(); precondition(q.errorMessage==nil && q.isFetching)
  await c.complete(4,"current"); await pause(); precondition(q.result == .value("current"))
  q.refresh(v,provider:p); await count(c,5); q.hide(v); await c.complete(5,"hidden"); await pause(); precondition(q.result == .value("current") && !q.isFetching)
  q.show(v,provider:p); await count(c,6); let v2=UUID(); q.show(v2,provider:p); q.hide(v)
  await c.complete(6,"shared"); await pause(); precondition(q.result == .value("shared")); q.hide(v2)
  let d=ControlledBalance(); let dq=ProviderBalanceQueryState(debounce:.milliseconds(40),fetch:{try await d.fetch($0)})
  dq.show(v,provider:p); p.apiKey="a"; dq.update(v,provider:p); p.apiKey="b"; dq.update(v,provider:p)
  await count(d,1); await pause(); n=await d.total(); precondition(n==1); await d.complete(1,"ok"); await pause(); dq.hide(v)
  let timeout=ProviderBalanceQueryState(debounce:.zero,timeout:.milliseconds(5),fetch:{_ in try await Task.sleep(for:.seconds(1)); return .value("late")})
  timeout.show(v,provider:p); await pause(); precondition(timeout.errorMessage=="查询超时，可稍后刷新" && !timeout.isFetching); timeout.hide(v)
  var original=ProviderConfiguration(); original.customAvatar="original"
  let draft=DraftHarness(original,onSave:{_ in false}); precondition(!draft.hasUnsavedChanges)
  draft.configuration.models.append("draft"); precondition(draft.hasUnsavedChanges); draft.configuration.models=[]; precondition(!draft.hasUnsavedChanges)
  draft.configuration.customAvatar="draft"; draft.requestDismiss(); precondition(draft.isLeaveConfirmationPresented && draft.dismissals==0)
  draft.save(); precondition(draft.isSaveErrorPresented && !draft.didSave && draft.dismissals==0 && AssistantMediaStore.removed.isEmpty)
  draft.discardAndDismiss(); precondition(draft.dismissals==1 && AssistantMediaStore.removed==["draft"])
  AssistantMediaStore.removed=[]; let saved=DraftHarness(original,onSave:{_ in true}); saved.configuration.customAvatar="saved"; saved.save()
  precondition(saved.didSave && saved.dismissals==1 && AssistantMediaStore.removed==["original"]); saved.cleanUpAvatarIfNeeded(); precondition(AssistantMediaStore.removed==["original"])
  print("PASS: production balance stale success/error, cancellation, shared surfaces, debounce, timeout; draft change/revert, save failure and avatar ownership")
 }
}
'''


def declaration(source: str, marker: str, after: int = 0) -> str:
    start = source.index(marker, after)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


STUBS += declaration((ROOT / "Mocca/AIChatService.swift").read_text(), "enum ProviderBalanceResult:") + "\n"

def extract(source: str) -> tuple[str, str, dict]:
    query_start = source.index("private struct ProviderBalanceQueryKey:")
    summary_start = source.index("private struct ProviderBalanceSummaryView:")
    query = source[query_start:summary_start]
    query = query.replace("private struct ProviderBalanceQueryKey:", "struct ProviderBalanceQueryKey:")
    query = query.replace("private final class ProviderBalanceQueryState", "final class ProviderBalanceQueryState")
    editor = source.index("struct ProviderEditorView:")
    method_markers = [
        "private func save()", "private var hasUnsavedChanges:", "private var canSave:",
        "private func requestDismiss()", "private func discardAndDismiss()", "private func cleanUpAvatarIfNeeded()",
    ]
    methods = [declaration(source, marker, editor) for marker in method_markers]
    methods = "\n".join(methods).replace("private func ", "func ").replace("private var ", "var ")
    host = STUBS + DRAFT_HARNESS + methods + "\n}\n" + query + TESTS
    ui_stubs = STUBS[:STUBS.index("@MainActor enum AssistantMediaStore")] + declaration((ROOT / "Mocca/AIChatService.swift").read_text(), "enum ProviderBalanceResult:")
    probe = declaration(source, "private struct ProviderDraftDismissObserver:")
    summary = declaration(source, "private struct ProviderBalanceSummaryView:")
    ui = "import SwiftUI\nimport UIKit\n" + ui_stubs + "\n" + probe + "\n" + query + "\n" + summary
    provenance = {
        "source": str(SOURCE),
        "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
        "extracted": method_markers + ["ProviderBalanceQueryKey", "ProviderBalanceQueryState", "ProviderDraftDismissObserver", "ProviderBalanceSummaryView"],
        "transformations": ["Production algorithms unchanged", "private access relaxed in the host harness", "App/network/media dependencies replaced with explicit fake receivers"],
        "checks": [
            "Disabled balance, missing key and invalid URL do not fetch",
            "Disabled chat provider can fetch balance",
            "Changed key rejects an old success while the new request remains active",
            "Changed API path rejects an old error while the new request remains active",
            "Models, avatar, ordinary name and chat enabled changes do not invalidate balance",
            "Last visible surface cancels and rejects a late completion",
            "Two surfaces share a query and one disappearing does not cancel the other",
            "Rapid input changes debounce to one request",
            "Timeout cancels a cooperative fetch and leaves a retryable error",
            "Provider model edits are dirty and reverting clears dirty",
            "Unsaved dismissal asks instead of leaving",
            "Failed save leaves draft open and preserves original avatar",
            "Discard removes only draft avatar; successful save removes only original avatar",
        ],
        "limitations": [
            "No real account requests or app/device/simulator launch",
            "The timeout races cancellation-aware URLSession work; a wholly noncooperative child could outlive the timeout before its task group returns",
            "SDK typecheck is not runtime acceptance of sheet swipe callbacks, nested presentation, List swipes or visual layout",
        ],
    }
    return host, ui, provenance


def run(label: str, args: list[str], timeout: int) -> dict:
    started = time.monotonic()
    completed = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, timeout=timeout)
    (OUTPUT / f"{label}.log").write_text(completed.stdout + completed.stderr)
    result = {"command": args, "exit_code": completed.returncode, "elapsed_seconds": round(time.monotonic() - started, 3)}
    if completed.returncode:
        print(completed.stdout + completed.stderr)
        raise RuntimeError(f"{label} failed; see {OUTPUT / (label + '.log')}")
    return result


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    source = SOURCE.read_text()
    host, ui, provenance = extract(source)
    host_path = OUTPUT / "ProviderPolishHostVerification.swift"
    ui_path = OUTPUT / "ProviderPolishUITypecheck.swift"
    executable = OUTPUT / "provider-polish-verification"
    host_path.write_text(host)
    ui_path.write_text(ui)
    results = {}
    results["host_compile"] = run("host-compile", ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(host_path), "-o", str(executable)], 90)
    results["host_checks"] = run("host-checks", [str(executable)], 30)
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    results["ui_typecheck"] = run("ui-typecheck", ["xcrun", "swiftc", "-typecheck", "-swift-version", "6", "-target", "arm64-apple-ios17.0-simulator", "-sdk", sdk, str(ui_path)], 120)
    provenance["results"] = results
    provenance["source_unchanged_during_run"] = SOURCE.read_text() == source
    assert provenance["source_unchanged_during_run"], "Product source changed during verification"
    (OUTPUT / "provenance.json").write_text(json.dumps(provenance, ensure_ascii=False, indent=2) + "\n")
    print((OUTPUT / "host-checks.log").read_text().strip())
    print(f"PASS: actual dismissal probe and balance summary typecheck; evidence: {OUTPUT}")


if __name__ == "__main__":
    main()

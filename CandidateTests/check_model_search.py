"""Compile the actual matcher with behavior cases and a local synthetic benchmark."""
from pathlib import Path
import subprocess,sys
from check_drawer_close_driver_reuse import extract
root=Path(__file__).resolve().parents[1];out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
matcher=extract((root/'Mocca/ProviderModels.swift').read_text(),r'^struct ModelSearchQuery')[0]
checks=r'''
let cases: [(String,[String],Bool)] = [
 ("",["anything"],true), ("  \n ",["anything"],true),
 ("DEEP",["deepseek-v4-pro"],true), ("gpt4o",["openai/gpt-4o"],true),
 ("gpt-4o",["GPT 4o"],true), ("claude sonnet",["claude-3-7-sonnet"],true),
 ("sonnet claude",["claude-3-7-sonnet"],true), ("openai mini",["gpt-4o-mini","OpenAI"],true),
 ("deep seek",["DeepSeek V4"],true), ("千问 推理",["千问-3 推理模型"],true),
 ("4.5",["claude-sonnet-4-5"],true), ("gpt4o",["gpt-4.1"],false),
 ("claude sonnet",["claude-opus-4-5"],false), ("/",["openai/gpt-4o"],true),
 ("---",["unrelated"],false), ("gpt /",["gpt-4o"],false),
 ("gpt\tmini",["gpt-4o-mini"],true), (" ",[""],true)
]
for (query, fields, expected) in cases {
 let actual = fields.count == 2 ? ModelSearchQuery(query).matches(fields[0],fields[1]) : ModelSearchQuery(query).matches(fields[0])
 precondition(actual == expected, "Query failed: \(query)")
}
print("PASS \(cases.count) matching cases")
let catalog=(0..<10000).map { ("vendor/claude-3-7-sonnet-\($0)","Claude Sonnet \($0)") }
for count in [200,1000,10000] {
 for raw in ["", "claude", "claude sonnet", "gpt4o"] {
  let query=ModelSearchQuery(raw)
  var samples:[Double]=[];var hits=0
  for _ in 0..<10 {
   let start=Date.timeIntervalSinceReferenceDate
   if query.isEmpty { hits=count } else { hits=catalog.prefix(count).filter { query.matches($0.0,$0.1) }.count }
   samples.append((Date.timeIntervalSinceReferenceDate-start)*1000)
  }
  samples.sort()
  print("PERF count=\(count) query=\(raw.debugDescription) median_ms=\(samples[5]) max_ms=\(samples.last!) hits=\(hits)")
 }
}
'''
(out/'main.swift').write_text('import Foundation\n'+matcher+'\n'+checks)
subprocess.run(['xcrun','swiftc','-O',str(out/'main.swift'),'-o',str(out/'check')],check=True)
subprocess.run([str(out/'check')],check=True)

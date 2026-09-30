#!/usr/bin/env python3
"""Build the combined product with simulator-only, artificial version fixtures."""
from pathlib import Path
import hashlib, json, shutil, subprocess

root = Path(__file__).resolve().parents[1]
out = root / 'work/version-code-integration'
lab = out / 'AppSource'
lab.mkdir(parents=True, exist_ok=True)
folders = ['Mocca', 'GenerationActivityExtension', 'Mocca.xcodeproj', 'Configuration']
for name in folders:
    shutil.copytree(root / name, lab / name, dirs_exist_ok=True)
p = lab / 'Mocca/AppModel.swift'
s = p.read_text()
a = s.index('        if name == .versions {', s.index('enum NativeReadingFixtures'))
b = s.index('        return Fixture(', a)
s = s[:a] + r'''        if name == .versions {
            for index in [3, 7] {
                let group = "native-version-\(index)"
                messages[index].versionGroupID = group
                messages[index].text = "短代码版本\n\n```swift\nlet small = 1\nlet text = \"中文🙂\"\nprint(text)\n```\n\nEND-\(index)-0"
                for version in 1...3 {
                    let body: String
                    if version == 2 {
                        body = "这是一条短回复。代码与文字版本切换时，下边缘应该留在原处。\n\n短回复第二段。"
                    } else {
                        let count = version == 1 ? 700 : 6
                        let lines = (0..<count).map {
                            "let value\(index)_\($0) = \($0) // 中文🙂 é العربية  "
                        }.joined(separator: "\n")
                        body = "人工代码版本 \(index)-\(version)\n\n```swift\n" + lines + "\n```"
                    }
                    messages.append(ChatMessage(
                        id: messageID(index, variant: version), conversationID: conversationID,
                        role: .assistant, text: body + "\n\nEND-\(index)-\(version)",
                        createdAt: date.addingTimeInterval(Double(index) + Double(version) / 10),
                        updatedAt: date.addingTimeInterval(Double(index) + Double(version) / 10),
                        versionGroupID: group, version: version))
                }
                let selected = index == 7 ? 2 : 1
                conversation.versionSelections[group] = selected
                selectedIDs[index] = messageID(index, variant: selected)
                if selected == 1 { longIDs.insert(selectedIDs[index]) }
            }
        }
''' + s[b:]
p.write_text(s)
p = lab / 'Mocca.xcodeproj/project.pbxproj'
p.write_text(p.read_text().replace('com.uuzsama450.mocca.migration', 'com.mocca.local.history-native-reading5075'))
manifest = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for folder in folders for p in (root / folder).rglob('*') if p.is_file()}
(out / 'source-inputs.json').write_text(json.dumps(manifest, indent=2))
cmd = ['nice', '-n', '10', 'xcodebuild', '-jobs', '2', 'build', '-project', str(lab / 'Mocca.xcodeproj'),
       '-scheme', 'Mocca', '-configuration', 'Debug', '-sdk', 'iphonesimulator',
       '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', str(out / 'AppDD'),
       '-clonedSourcePackagesDirPath', str(out / 'Packages'),
       '-onlyUsePackageVersionsFromResolvedFile', '-skipPackageUpdates',
       'MOCCA_BUNDLE_IDENTIFIER=com.mocca.local.history-native-reading5075',
       'CODE_SIGNING_ALLOWED=NO', 'ARCHS=x86_64', 'ONLY_ACTIVE_ARCH=YES']
(out / 'build-command.json').write_text(json.dumps(cmd, indent=2))
with (out / 'build.log').open('w') as log:
    result = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT)
print('Build exit:', result.returncode)
raise SystemExit(result.returncode)

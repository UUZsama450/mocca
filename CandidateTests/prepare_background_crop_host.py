"""A small simulator host for the shipping cropper and actual media writer."""
from pathlib import Path
import subprocess,sys,re,shutil
root=Path(__file__).resolve().parents[1];out=Path(sys.argv[1]).resolve()
out.mkdir(parents=True,exist_ok=False)
for child in root.iterdir():
 if child.is_dir() and child.name not in {"work", ".git", "Mocca.xcodeproj"}:
  (out/child.name).symlink_to(child,target_is_directory=True)
shutil.copytree(root/"Mocca.xcodeproj",out/"Mocca.xcodeproj",ignore=shutil.ignore_patterns("xcuserdata"))
project=out/"Mocca.xcodeproj/project.pbxproj"
original=project.read_text()
# Historical target patch predates this file; stage its declarations afterward.
additions=[line for line in original.splitlines(keepends=True) if 'BackgroundImageCropEditor.swift' in line]
text=''.join(line for line in original.splitlines(keepends=True) if 'BackgroundImageCropEditor.swift' not in line)
patch=(root/"CandidateTests/StorageSaveTestHost.patch").read_text()
for hunk in re.split(r"^@@.*@@.*\n",patch,flags=re.M)[1:]:
 lines=hunk.splitlines(keepends=True)
 before="".join(line[1:] for line in lines if line.startswith((" ","-")))
 after="".join(line[1:] for line in lines if line.startswith((" ","+")))
 prefix="/* End PBXTargetDependency section */\n\n"
 if before.startswith(prefix) and before not in text:
  before=before[len(prefix):];after=after[len(prefix):]
 if text.count(before)==0:
  section=next((line for line in lines if line.startswith(" /* Begin PBX") and "section */" in line),None)
  hunk_additions="".join(line[1:] for line in lines if line.startswith("+"))
  assert section is not None and hunk_additions,"Unreviewed crop test context drift"
  anchor=section[1:];assert text.count(anchor)==1
  text=text.replace(anchor,anchor+hunk_additions,1)
 else:
  assert text.count(before)==1
  text=text.replace(before,after,1)
for line in additions:
 if 'isa = PBXBuildFile' in line: anchor='/* Begin PBXBuildFile section */\n'
 elif 'isa = PBXFileReference' in line: anchor='/* Begin PBXFileReference section */\n'
 elif 'in Sources' in line: anchor='\t\t\t\t1A57A5D201B7C0DEA1140003 /* AssistantViews.swift in Sources */,\n'
 else: anchor='\t\t\t\t1A57A5D201B7C0DEA1140004 /* AssistantViews.swift */,\n'
 assert text.count(anchor)==1
 text=text.replace(anchor,anchor+line,1)
project.write_text(text)
schemes=out/'Mocca.xcodeproj/xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
shutil.copyfile(root/'CandidateTests/StorageSaveValidation.xcscheme',schemes/'Slice1Validation.xcscheme')
(out/'Slice1UITests').mkdir()

p=out/'Mocca';p.unlink();p.mkdir()
for name in ['Assets.xcassets','AppIcon.icon']:
 shutil.copytree(root/'Mocca'/name,p/name)
for name in ['Info.plist','Localizable.xcstrings','InfoPlist.xcstrings','GenerationActivityAttributes.swift','PrivacyInfo.xcprivacy']:
 if (root/'Mocca'/name).exists():shutil.copyfile(root/'Mocca'/name,p/name)
for child in (root/'Mocca').iterdir():
 if child.suffix != '.swift' and not (p/child.name).exists():
  (p/child.name).symlink_to(child,target_is_directory=child.is_dir())
shutil.copyfile(root/'Mocca/BackgroundImageCropEditor.swift',p/'BackgroundImageCropEditor.swift')
media=(root/'Mocca/AssistantModels.swift').read_text().split('enum AssistantMediaStore {',1)[1]
(p/'MoccaApp.swift').write_text('''import SwiftUI
import UIKit
@main struct MoccaApp: App { var body: some Scene { WindowGroup { Text("Synthetic crop validation") } } }
enum L10n { static func lookup(_ key:String)->String { key } }
enum ConversationStoreError: Error { case missingApplicationSupport }
enum AssistantMediaStore {'''+media)
project=out/'Mocca.xcodeproj/project.pbxproj';s=project.read_text().replace('com.uuzsama450.mocca.migration','com.uuzsama450.mocca.crop5091qa')
pattern=r'(isa = PBXSourcesBuildPhase;\n\s*buildActionMask = 2147483647;\n\s*files = \()(.*?)(\n\s*\);)'
def limit(match):
 body=match.group(2)
 if 'MoccaApp.swift in Sources' not in body:return match.group(0)
 lines=[line for line in body.splitlines() if any(x in line for x in ['MoccaApp.swift in Sources','BackgroundImageCropEditor.swift in Sources'])]
 assert len(lines)==2
 return match.group(1)+'\n'+'\n'.join(lines)+match.group(3)
s=re.sub(pattern,limit,s,flags=re.S);project.write_text(s)
harness=(root/'CandidateTests/BackgroundCropCommitHarness.swift').read_text()
for filename,start,end,marker in [
 ('SettingsViews.swift','    private func saveCroppedSidebarBackground(', '    private func clearSidebarBackground()', '// SIDEBAR_COMMIT'),
 ('AssistantViews.swift','    private func saveCroppedBackground(', '    private func save()', '// ASSISTANT_COMMIT')]:
 source=(root/'Mocca'/filename).read_text()
 body=source[source.index(start):source.index(end,source.index(start))]
 harness=harness.replace(marker,body.replace('private func','func',1))
p=out/'Mocca/MoccaApp.swift';p.write_text(p.read_text()+'\n'+harness)
p=out/'Mocca/BackgroundImageCropEditor.swift';s=p.read_text()
marker='    nonisolated static func save(_ image: UIImage, destination: BackgroundCropDestination) async -> String? {\n'
assert s.count(marker)==1
s=s.replace(marker,marker+'        await CropSaveGate.wait()\n        return ',1)
p.write_text(s)
(out/'Slice1UITests/Slice1UITests.swift').write_text((root/'CandidateTests/BackgroundCropTests.swift').read_text()+'\n'+(root/'CandidateTests/BackgroundCropCommitTests.swift').read_text())

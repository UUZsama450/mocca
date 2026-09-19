"""Ensure the routing change retains existing generation/storage/window policy."""
from pathlib import Path
import subprocess,json,sys
root=Path(__file__).resolve().parents[1]
base='46c06741feb53ae18a8a93cec468b8b4b7892261'
def baseline(path):return subprocess.check_output(['git','show',f'{base}:{path}'],cwd=root,text=True)
def block(s,marker):
 start=s.index(marker);opening=s.index('{',start);end=opening+1;depth=1
 while depth:
  depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end]
old=baseline('Mocca/AppModel.swift');new=(root/'Mocca/AppModel.swift').read_text()
methods=['private func appendStreamingEvent(', 'private func publishStreamingTextDisplay(', 'private func finishStreaming(', 'func persistableConversationSnapshot()', 'private func makeBackupRestoreModelRollback()', 'func selectConversation(_ id: UUID, closeDrawer:', 'private func appendMessagePreservingLatestWindow(', 'private func restoreConversationSnapshot(', 'private func prepareConversationSave(', 'private func applyConversationSaveOutcome(']
results={m:block(old,m)==block(new,m).replace('conversationMessageStore[','messagesByConversation[') for m in methods}
for path in ['Mocca/RootView.swift','Mocca/SettingsViews.swift']:
 results[path+' only per-key accessor renamed']=baseline(path)==(root/path).read_text().replace('model.conversationMessageStore[','model.messagesByConversation[')
for path in ['Mocca/ConversationStore.swift','Mocca/MessageMarkdownView.swift','Mocca.xcodeproj/project.pbxproj']:
 results[path+' unchanged']=baseline(path)==(root/path).read_text()
assert all(results.values()),results
print(json.dumps(results,indent=2))

"""Resource validity and unchanged hot-path ownership; not a device FPS test."""
from pathlib import Path
import json,re,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
BASE='b31ddc52dce2ce2408a075059613a39b6f898103'
def original(path):
    return subprocess.check_output(['git','show',f'{BASE}:{path}'],cwd=ROOT,text=True)
def block(s,marker):
    start=s.index(marker);opening=s.index('{',start);depth=1;end=opening+1
    while depth:
        depth+=(s[end]=='{')-(s[end]=='}');end+=1
    return s[start:end]
results={}
# All business state, streaming, cache and persistence code in AppModel is byte-identical.
p='Mocca/AppModel.swift';a=original(p);b=(ROOT/p).read_text()
assert a[a.index('final class AppModel {'):]==b[b.index('final class AppModel {'):]
results['AppModel business state, cache, streaming and persistence unchanged']=True
markers=['private final class DrawerPresentationProgressTracker {',
 'private final class DrawerSettleDisplayLinkDriver:',
 'private final class DrawerLiveMainPanelController:',
 'private struct DrawerLiveMainPanelHost:',
 'private struct DrawerDetachedMainPanelMotionModifier:',
 'private struct DrawerAwareMessageNavigationPanelVisibility:',
 'private struct DrawerAwareQuickReturnToBottom:',
 'private struct ConversationDrawer:',
 'private struct DrawerContentMotionModifier:',
 'private struct DrawerUnreadReplyIndicator:',
 'private struct ConversationDrawerRowIdentity:',
 'private func settleDrawer(',
 'private func setDrawerGestureActive(',
 'private func conversationDateGroups(']
p='Mocca/RootView.swift';a=original(p);b=(ROOT/p).read_text()
for marker in markers:
    assert block(a,marker)==block(b,marker),marker
results['drawer motion, simple navigation visibility and unread leaf unchanged']=len(markers)
parent=block(b,'private struct ConversationDrawerContent:')
assert 'unreadReplyConversationIDs' not in parent
assert b.count('model.unreadReplyConversationIDs')==1
assert parent.count('DrawerUnreadReplyIndicator(')==2
results['unread observation still confined to dot leaf']=True
p='Mocca/AppLocalization.swift';s=(ROOT/p).read_text()
assert 'AppModel' not in s
assert '.id(' not in s
assert 'if languageCode != resolved' in s
assert 'guard self.selection != selection' in s
results['language state separate from AppModel; unchanged-language guard']=True
p='Mocca/ConversationStore.swift'
assert block(original(p),'struct Conversation:')==block((ROOT/p).read_text(),'struct Conversation:')
results['persisted model identifiers and default title unchanged']=True
for p in ['Mocca/Localizable.xcstrings','Mocca/InfoPlist.xcstrings']:
    catalog=json.loads((ROOT/p).read_text())
    assert catalog['sourceLanguage']=='zh-Hans'
    for key,item in catalog['strings'].items():
        en=item['localizations']['en']['stringUnit']
        zh=item['localizations'].get('zh-Hans',{'stringUnit':{'state':'translated','value':key}})['stringUnit']
        assert en['state']=='translated' and en['value'],(p,key)
        assert zh['state']=='translated' and zh['value'],(p,key)
        # All hand-wrapped dynamic keys use %@; %% is a literal percent.
        pattern=r'%(?:\d+\$)?@'
        assert len(re.findall(pattern,zh['value']))==len(re.findall(pattern,en['value'])),key
    results[p+' complete entries']=len(catalog['strings'])
text=json.dumps({'baseline':BASE,'checks':results,'scope':'Source contracts and catalog integrity, not rendering cost or physical-device frame times.'},indent=2,ensure_ascii=False)+'\n'
if len(sys.argv)>1:Path(sys.argv[1]).write_text(text)
print(text)

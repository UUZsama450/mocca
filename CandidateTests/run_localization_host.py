from pathlib import Path
import subprocess,json,sys
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(sys.argv[1]).resolve();OUT.mkdir(parents=True,exist_ok=True)
bundle=OUT/'Resources.bundle';bundle.mkdir(exist_ok=True)
subprocess.run(['xcrun','xcstringstool','compile',str(ROOT/'Mocca/Localizable.xcstrings'),'--output-directory',str(bundle)],check=True)
source=(ROOT/'Mocca/AppLocalization.swift').read_text()
# This host harness exercises localization logic, not the settings UI label.
a=source.index('struct AppLanguagePicker:');b=source.index('// The stored placeholder',a)
source=source[:a]+source[b:]
source=source.replace('static let shared = AppLocalization()','static let shared = AppLocalization(defaults: UserDefaults(suiteName: "Mocca.Localization.IsolatedHost")!)')
source=source.replace('Bundle.main.path(', 'Bundle(path: '+json.dumps(str(bundle))+')!.path(')
service=(ROOT/'Mocca/AIChatService.swift').read_text()
a=service.index('enum ProviderBalanceResult:');b=service.index('struct ChatRequestImage:',a)
source += '\n'+service[a:b]
source += '\nstruct Conversation { static let defaultTitle = "新聊天"; var title: String }\n'
(OUT/'AppLocalization.swift').write_text(source)
subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(OUT/'AppLocalization.swift'),str(ROOT/'CandidateTests/LocalizationHostTests.swift'),'-o',str(OUT/'tests')],check=True)
r=subprocess.run([str(OUT/'tests')],capture_output=True,text=True,check=True)
(OUT/'result.txt').write_text(r.stdout+r.stderr);print(r.stdout)

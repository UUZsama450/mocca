"""Run the prepared full-app host against frozen product inputs and private fault hooks."""
from pathlib import Path
import json,subprocess,time,hashlib,sys
root=Path(__file__).resolve().parents[1];out=root/'work/review-tests';host=root/'work/review-test-host';label=sys.argv[1]
app_source=(root/'Mocca/AppModel.swift').read_text()+'\n'+(root/'CandidateTests/ReviewCorrectnessTestHooks.swift').read_text()
if (host/'Mocca/AppModel.swift').read_text()!=app_source: (host/'Mocca/AppModel.swift').write_text(app_source)
(host/'Slice1UITests/Slice1UITests.swift').write_text((root/'CandidateTests/ReviewCorrectnessTests.swift').read_text())
project=host/'Mocca.xcodeproj/project.pbxproj';project.write_text(project.read_text().replace('CURRENT_PROJECT_VERSION = 5046;', 'CURRENT_PROJECT_VERSION = 5047;'))
cmd=json.loads((out/'hosted-command.json').read_text());cmd[cmd.index('-resultBundlePath')+1]=str(out/(label+'.xcresult'))
tracked=subprocess.check_output(['git','ls-files','Mocca','Mocca.xcodeproj','GenerationActivityExtension'],cwd=root,text=True).splitlines()
manifest={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in tracked if (root/p).is_file()}
(out/(label+'-inputs.json')).write_text(json.dumps(manifest,indent=2));(out/(label+'-command.json')).write_text(json.dumps(cmd,indent=2))
start=time.time()
with (out/(label+'.log')).open('w') as log:result=subprocess.run(cmd,cwd=host,stdout=log,stderr=subprocess.STDOUT)
unchanged=all(hashlib.sha256((root/p).read_bytes()).hexdigest()==h for p,h in manifest.items())
proof={'exit_code':result.returncode,'seconds':time.time()-start,'product_inputs_unchanged':unchanged,'product_input_count':len(manifest),'synthetic_stores_only':True}
(out/(label+'-result.json')).write_text(json.dumps(proof,indent=2));print(proof)
raise SystemExit(result.returncode or (0 if unchanged else 1))

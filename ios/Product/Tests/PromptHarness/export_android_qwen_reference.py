"""Export existing upstream-generated Android goldens without running a network fetch."""
import hashlib,json,re
from pathlib import Path
repo=Path(__file__).resolve().parents[4]
source=repo/'core/common/src/jvmAndAndroidTest/kotlin/io/github/alpharomercoma/openweights/core/common/model/Qwen3PromptFixtures.kt'
text=source.read_text();matches=list(re.finditer(r'const val (\w+): String\s*=',text));values={}
for i,m in enumerate(matches):
 part=text[m.end():matches[i+1].start() if i+1<len(matches) else len(text)]
 values[m.group(1)]=''.join(json.loads(s)for s in re.findall(r'"(?:\\.|[^"\\])*"',part))
assert len(values)==9
p=repo/'ios/Product/Tests/OpenWeightsCoreTests/Fixtures/android-qwen3-prompt-reference.json'
p.write_text(json.dumps({'source':str(source.relative_to(repo)),'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'reference':values},indent=2,ensure_ascii=False)+'\n')
print(p.name)

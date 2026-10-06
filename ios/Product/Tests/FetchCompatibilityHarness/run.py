#!/usr/bin/env python3
import hashlib,json,subprocess,zipfile
from datetime import datetime,timezone
from pathlib import Path
root=Path(__file__).resolve().parents[2]
generated=root/'.build/fetch-compatibility-harness';sources=generated/'Sources/FetchCompatibilityHarness';sources.mkdir(parents=True,exist_ok=True)
inputs=[root/'Package.swift',root/'Package.resolved',Path(__file__),Path(__file__).with_name('Checks.swift'),root/'DeviceTests/FetchDecoderFixtures.swift',Path(__file__).with_name('CharsetReference.java'),Path(__file__).with_name('jdk21-reference.json')]+sorted((root/'Sources/OpenWeightsCore').glob('*.swift'))
digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
hashes={str(p.relative_to(root)):digest(p)for p in inputs}
(sources/'FetchDecoderFixtures.swift').write_bytes((root/'DeviceTests/FetchDecoderFixtures.swift').read_bytes())
(sources/'Checks.swift').write_bytes(Path(__file__).with_name('Checks.swift').read_bytes())
(generated/'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "FetchCompatibilityHarness", platforms: [.macOS(.v14)], dependencies: [.package(path: "../..")], targets: [.executableTarget(name: "FetchCompatibilityHarness", dependencies: [.product(name: "OpenWeightsCore", package: "Product")])])
''')
swift=subprocess.check_output(['swift','--version'],text=True).strip();started=datetime.now(timezone.utc).isoformat()
identity=hashlib.sha256(json.dumps({'sources':hashes,'swift':swift,'started':started},sort_keys=True).encode()).hexdigest()[:12]
jdkReceipt=root.parent/'Benchmark/Results/android-jdk21-2026-10-02.json'
jdkInfo=json.loads(jdkReceipt.read_text());jdk=root.parent/'Benchmark'/jdkInfo['javaHome']
javaRun=subprocess.run([str(jdk/'bin/java'),'--source','21',str(Path(__file__).with_name('CharsetReference.java'))],capture_output=True,text=True)
assert javaRun.returncode==0,javaRun.stderr
javaRows=json.loads(javaRun.stdout);assert javaRows==json.loads(Path(__file__).with_name('jdk21-reference.json').read_text())
javaVersion=subprocess.check_output([str(jdk/'bin/java'),'-version'],stderr=subprocess.STDOUT,text=True).strip()
output=root/f'Results/fetch-decoder-host-{identity}.json';log=root/f'.build/fetch-decoder-host-{identity}.log'
with zipfile.ZipFile(root/f'Results/fetch-decoder-host-{identity}-sources.zip','w',zipfile.ZIP_DEFLATED)as z:
 for p in inputs:z.write(p,str(p.relative_to(root)))
with log.open('w')as out:
 result=subprocess.run(['swift','run','--package-path',str(generated),'--scratch-path',str(root/'.build/fetch-compatibility-harness-build'),'-c','release','FetchCompatibilityHarness',str(output)],stdout=out,stderr=subprocess.STDOUT)
assert hashes=={str(p.relative_to(root)):digest(p)for p in inputs},'Fetch decoder inputs changed during validation.'
proof=json.loads(output.read_text())if output.exists()else{'status':'live-fetch-compatibility-harness-failed-before-observation'}
if result.returncode==0:
 assert len(proof['cases'])==len(javaRows)
 for actual,reference in zip(proof['cases'],javaRows):
  assert actual['charset']==reference['charset'] and actual['inputHex']==reference['hex'] and actual['javaCodePoints']==reference['codePoints']
proof.update(javaRuntime=javaVersion,javaBinarySHA256=digest(jdk/'bin/java'),jdkReceiptSHA256=digest(jdkReceipt),compiledSourceSHA256=hashes,swift=swift,startedAtUTC=started,exitCode=result.returncode,logSHA256=digest(log),sourceSnapshot=f'fetch-decoder-host-{identity}-sources.zip')
output.write_text(json.dumps(proof,indent=2,sort_keys=True)+'\n');print(output.name)
if result.returncode:raise SystemExit(result.returncode)

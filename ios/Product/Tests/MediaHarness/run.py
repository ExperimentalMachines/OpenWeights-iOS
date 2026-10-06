#!/usr/bin/env python3
import hashlib,json,subprocess,zipfile
from datetime import datetime,timezone
from pathlib import Path
root=Path(__file__).resolve().parents[2]
generated=root/'.build/media-harness';sources=generated/'Sources/MediaHarness';sources.mkdir(parents=True,exist_ok=True)
inputs=[root/'Package.swift',root/'Package.resolved',Path(__file__),Path(__file__).with_name('Checks.swift')]+sorted((root/'Sources/OpenWeightsCore').glob('*.swift'))
digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
hashes={str(p.relative_to(root)):digest(p)for p in inputs}
(sources/'Checks.swift').write_bytes(Path(__file__).with_name('Checks.swift').read_bytes())
(generated/'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MediaHarness", platforms: [.macOS(.v14)], dependencies: [.package(path: "../..")], targets: [.executableTarget(name: "MediaHarness", dependencies: [.product(name: "OpenWeightsCore", package: "Product")])])
''')
swift=subprocess.check_output(['swift','--version'],text=True).strip();started=datetime.now(timezone.utc).isoformat()
identity=hashlib.sha256(json.dumps({'sources':hashes,'swift':swift,'started':started},sort_keys=True).encode()).hexdigest()[:12]
output=root/f'Results/media-providers-host-{identity}.json';log=root/f'.build/media-providers-host-{identity}.log'
with zipfile.ZipFile(root/f'Results/media-providers-host-{identity}-sources.zip','w',zipfile.ZIP_DEFLATED)as z:
 for p in inputs:z.write(p,str(p.relative_to(root)))
with log.open('w')as out:
 result=subprocess.run(['swift','run','--package-path',str(generated),'--scratch-path',str(root/'.build/media-harness-build'),'-c','release','MediaHarness',str(output)],stdout=out,stderr=subprocess.STDOUT)
assert hashes=={str(p.relative_to(root)):digest(p)for p in inputs},'Media inputs changed during validation.'
proof=json.loads(output.read_text())if output.exists()else{'status':'live-media-harness-failed-before-observation'}
proof.update(compiledSourceSHA256=hashes,swift=swift,startedAtUTC=started,exitCode=result.returncode,logSHA256=digest(log),sourceSnapshot=f'media-providers-host-{identity}-sources.zip')
output.write_text(json.dumps(proof,indent=2,sort_keys=True)+'\n');print(output.name)
if result.returncode:raise SystemExit(result.returncode)

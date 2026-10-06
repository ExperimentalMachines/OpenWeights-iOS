#!/usr/bin/env python3
import hashlib,json,subprocess,zipfile
from datetime import datetime,timezone
from pathlib import Path
root=Path(__file__).resolve().parents[2]
generated=root/'.build/proxy-harness';sources=generated/'Sources/ProxyHarness';sources.mkdir(parents=True,exist_ok=True)
inputs=[root/'Package.swift',root/'Package.resolved',Path(__file__),Path(__file__).with_name('Checks.swift'),root/'DeviceTests/ProxyFixture.swift']+sorted((root/'Sources/OpenWeightsCore').glob('*.swift'))
digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
hashes={str(p.relative_to(root)):digest(p)for p in inputs}
(sources/'ProxyFixture.swift').write_bytes((root/'DeviceTests/ProxyFixture.swift').read_bytes())
(sources/'Checks.swift').write_bytes(Path(__file__).with_name('Checks.swift').read_bytes())
(generated/'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ProxyHarness", platforms: [.macOS(.v14)], dependencies: [.package(path: "../..")], targets: [.executableTarget(name: "ProxyHarness", dependencies: [.product(name: "OpenWeightsCore", package: "Product")])])
''')
swift=subprocess.check_output(['swift','--version'],text=True).strip();started=datetime.now(timezone.utc).isoformat()
identity=hashlib.sha256(json.dumps({'sources':hashes,'swift':swift,'started':started},sort_keys=True).encode()).hexdigest()[:12]
output=root/f'Results/proxy-transport-host-{identity}.json';log=root/f'.build/proxy-transport-host-{identity}.log'
with zipfile.ZipFile(root/f'Results/proxy-transport-host-{identity}-sources.zip','w',zipfile.ZIP_DEFLATED)as z:
 for p in inputs:z.write(p,str(p.relative_to(root)))
with log.open('w')as out:
 result=subprocess.run(['swift','run','--package-path',str(generated),'--scratch-path',str(root/'.build/proxy-harness-build'),'-c','release','ProxyHarness',str(output)],stdout=out,stderr=subprocess.STDOUT)
assert hashes=={str(p.relative_to(root)):digest(p)for p in inputs},'Proxy inputs changed during validation.'
proof=json.loads(output.read_text())if output.exists()else{'status':'live-proxy-harness-failed-before-observation'}
proof.update(compiledSourceSHA256=hashes,swift=swift,startedAtUTC=started,exitCode=result.returncode,logSHA256=digest(log),sourceSnapshot=f'proxy-transport-host-{identity}-sources.zip')
output.write_text(json.dumps(proof,indent=2,sort_keys=True)+'\n');print(output.name)
if result.returncode:raise SystemExit(result.returncode)

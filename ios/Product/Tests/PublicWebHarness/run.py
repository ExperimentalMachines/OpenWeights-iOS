#!/usr/bin/env python3
"""Compile canonical Apple public-web transport and run live, noncredentialed host checks."""
import hashlib
import json
import subprocess
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
generated = root / '.build/public-web-harness'
sources = generated / 'Sources/PublicWebHarness'
sources.mkdir(parents=True, exist_ok=True)
inputs = [root / 'Package.swift', Path(__file__), Path(__file__).with_name('Checks.swift')]
inputs += sorted((root / 'Sources/OpenWeightsCore').glob('*.swift'))
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
hashes = {str(path.relative_to(root)): digest(path) for path in inputs}
swift = subprocess.check_output(['swift', '--version'], text=True).strip()
identity = hashlib.sha256(json.dumps({'sources': hashes, 'swift': swift}, sort_keys=True).encode()).hexdigest()[:12]
output = root / f'Results/public-web-transport-host-{identity}.json'
(sources / 'Checks.swift').write_bytes(Path(__file__).with_name('Checks.swift').read_bytes())
(generated / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PublicWebHarness", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "PublicWebHarness", dependencies: [.product(name: "OpenWeightsCore", package: "Product")])])
''')
log = root / f'.build/public-web-transport-{identity}.log'
with log.open('w') as stream:
    result = subprocess.run(['swift', 'run', '--package-path', str(generated), '--scratch-path', str(root / '.build/public-web-harness-build'),
                             '-c', 'release', 'PublicWebHarness', str(output)], stdout=stream, stderr=subprocess.STDOUT)
assert hashes == {str(path.relative_to(root)): digest(path) for path in inputs}, 'Canonical transport inputs changed during validation.'
proof = json.loads(output.read_text()) if output.exists() else {'passedChecks': [], 'observations': []}
if result.returncode:
    proof.update(status='apple-public-web-transport-host-check-failed', exitCode=result.returncode)
proof.update(compiledSourceSHA256=hashes, swift=swift, logSHA256=digest(log))
archive = root / f'Results/public-web-transport-sources-{identity}.zip'
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as snapshot:
    for path in inputs:
        snapshot.write(path, str(path.relative_to(root)))
proof['sourceSnapshot'] = {'file': archive.name, 'sha256': digest(archive)}
output.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
print(output.name)
if result.returncode:
    raise SystemExit(f'Live host transport checks failed. Inspect {log.name}')
print(f"{len(proof['passedChecks'])} canonical public-web transport checks passed.")

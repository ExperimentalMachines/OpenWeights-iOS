#!/usr/bin/env python3
"""Compile the actual discovery controller and API transport with bounded checks."""
import hashlib
import json
import subprocess
import sys
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
mode = 'live' if '--live' in sys.argv else 'fixture'
generated = root / '.build/discovery-harness'
sources = generated / 'Sources/DiscoveryHarness'
sources.mkdir(parents=True, exist_ok=True)
inputs = [root / 'App/DiscoveryController.swift', root / 'App/HubClient.swift', root / 'App/HubCredentialController.swift', root / 'App/HubGGUFRangeSource.swift', Path(__file__), Path(__file__).with_name('Checks.swift'), root / 'Package.swift', root / 'Package.resolved']
inputs += sorted((root / 'Sources/OpenWeightsCore').glob('*.swift'))
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
before = {str(p.relative_to(root)): digest(p) for p in inputs}
for name in ['DiscoveryController.swift', 'HubClient.swift', 'HubCredentialController.swift', 'HubGGUFRangeSource.swift']:
    (sources / name).write_bytes((root / 'App' / name).read_bytes())
(sources / 'Checks.swift').write_bytes(Path(__file__).with_name('Checks.swift').read_bytes())
(generated / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DiscoveryHarness", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "DiscoveryHarness", dependencies: [.product(name: "OpenWeightsCore", package: "Product")])])
''')
swift = subprocess.check_output(['swift', '--version'], text=True).strip()
identity = hashlib.sha256(json.dumps({'sources': before, 'swift': swift, 'mode': mode}, sort_keys=True).encode()).hexdigest()[:12]
output = root / f'Results/discovery-{mode}-host-{identity}.json'
log = root / f'.build/discovery-{mode}-harness.log'
with log.open('w') as stream:
    result = subprocess.run(['swift', 'run', '--package-path', str(generated), '--scratch-path', str(root / '.build/discovery-harness-build'), '-c', 'release', 'DiscoveryHarness', str(output), mode], stdout=stream, stderr=subprocess.STDOUT)
assert before == {str(p.relative_to(root)): digest(p) for p in inputs}, 'Discovery source changed during validation.'
if result.returncode:
    raise SystemExit(f'Discovery {mode} checks failed. Inspect {log}')
proof = json.loads(output.read_text())
proof.update(compiledSourceSHA256=before, swift=swift, logSHA256=digest(log))
archive = output.with_name(output.stem + '-sources.zip')
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as snapshot:
    for path in inputs:
        snapshot.write(path, str(path.relative_to(root)))
proof['sourceSnapshot'] = archive.name
output.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
print(f"{len(proof['passedChecks'])} discovery {mode} checks passed. {output.name}")

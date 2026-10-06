#!/usr/bin/env python3
"""Exercise the actual model import controller without network calls or inference claims."""
import hashlib
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[2]
generated = root / '.build/import-harness'
sources = generated / 'Sources/ImportHarness'
sources.mkdir(parents=True, exist_ok=True)
inputs = [root / 'App/HubCredentialController.swift', root / 'App/ModelDownloads.swift', root / 'App/HubClient.swift', root / 'App/HubGGUFRangeSource.swift', Path(__file__), Path(__file__).with_name('Checks.swift')]
inputs += [root / 'Package.swift', root / 'Package.resolved']
inputs += sorted((root / 'Sources/OpenWeightsCore').glob('*.swift'))


def hashes():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}


before = hashes()
(sources / 'HubCredentialController.swift').write_bytes((root / 'App/HubCredentialController.swift').read_bytes())
(sources / 'ModelDownloads.swift').write_bytes((root / 'App/ModelDownloads.swift').read_bytes())
(sources / 'HubClient.swift').write_bytes((root / 'App/HubClient.swift').read_bytes())
(sources / 'HubGGUFRangeSource.swift').write_bytes((root / 'App/HubGGUFRangeSource.swift').read_bytes())
(sources / 'Checks.swift').write_bytes(Path(__file__).with_name('Checks.swift').read_bytes())
(generated / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ImportHarness", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "ImportHarness", dependencies: [.product(name: "OpenWeightsCore", package: "Product")])])
''')
swift = subprocess.check_output(['swift', '--version'], stderr=subprocess.STDOUT, text=True).strip()
identity = hashlib.sha256(json.dumps({'sources': before, 'swift': swift}, sort_keys=True).encode()).hexdigest()[:12]
output = root / f'Results/model-import-controller-host-{identity}.json'
with (root / '.build/import-harness.log').open('w') as log:
    result = subprocess.run(['swift', 'run', '--package-path', str(generated), '--scratch-path', str(root / '.build/import-harness-build'),
                             '-c', 'release', 'ImportHarness', str(output)], stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    raise SystemExit(f'Import controller checks failed. Inspect {root / ".build/import-harness.log"}')
assert before == hashes(), 'Source changed during host validation.'
proof = json.loads(output.read_text())
proof['compiledSourceSHA256'] = before
proof['swift'] = swift
output.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
print(f"{len(proof['passedChecks'])} canonical import controller checks passed. {output.name}")

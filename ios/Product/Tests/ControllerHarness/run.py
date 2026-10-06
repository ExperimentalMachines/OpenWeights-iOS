#!/usr/bin/env python3
"""Exercise canonical chat controllers with a mock runtime, without claiming inference."""
import hashlib
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[2]
generated = root / '.build/controller-harness'
sources = generated / 'Sources/ControllerHarness'
sources.mkdir(parents=True, exist_ok=True)
inputs = [root / 'App/ChatController.swift', root / 'App/WatchController.swift', root / 'App/ConversationCompactor.swift', root / 'App/MemoryController.swift', root / 'App/WorkspaceController.swift', root / 'App/Runtime.swift', root / 'App/WebController.swift',
          Path(__file__), Path(__file__).with_name('Checks.swift')]
inputs.append(Path(__file__).with_name('WatchChecks.swift'))
inputs.append(Path(__file__).with_name('WebChecks.swift'))
inputs.append(Path(__file__).with_name('SearchChecks.swift'))
inputs.append(Path(__file__).with_name('MediaChecks.swift'))
inputs.append(Path(__file__).with_name('ProxyChecks.swift'))
inputs.append(Path(__file__).with_name('ScriptChecks.swift'))
inputs.append(Path(__file__).with_name('CanvasChecks.swift'))
inputs.append(Path(__file__).with_name('SettingsChecks.swift'))
inputs.append(Path(__file__).with_name('UsageChecks.swift'))
inputs.append(Path(__file__).with_name('ConversationChecks.swift'))
inputs.append(root / 'App/AttachmentController.swift')
inputs.append(Path(__file__).with_name('AttachmentChecks.swift'))
inputs.append(Path(__file__).with_name('MemoryEditingChecks.swift'))
inputs.append(Path(__file__).with_name('ResearchChecks.swift'))
inputs += [root / 'Package.swift', root / 'Package.resolved']
inputs += list((root / 'Sources/OpenWeightsCore').glob('*.swift'))
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
for name in ['AttachmentController.swift', 'ChatController.swift', 'WatchController.swift', 'ConversationCompactor.swift', 'MemoryController.swift', 'WorkspaceController.swift', 'WebController.swift']:
    (sources / name).write_bytes((root / 'App' / name).read_bytes())
runtime = (root / 'App/Runtime.swift').read_text()
(sources / 'RuntimeContracts.swift').write_text(runtime[:runtime.index('enum RuntimeFactory {')])
(sources / 'Checks.swift').write_bytes(Path(__file__).with_name('Checks.swift').read_bytes())
(sources / 'WatchChecks.swift').write_bytes(Path(__file__).with_name('WatchChecks.swift').read_bytes())
(sources / 'WebChecks.swift').write_bytes(Path(__file__).with_name('WebChecks.swift').read_bytes())
(sources / 'SearchChecks.swift').write_bytes(Path(__file__).with_name('SearchChecks.swift').read_bytes())
(sources / 'MediaChecks.swift').write_bytes(Path(__file__).with_name('MediaChecks.swift').read_bytes())
(sources / 'ProxyChecks.swift').write_bytes(Path(__file__).with_name('ProxyChecks.swift').read_bytes())
(sources / 'ScriptChecks.swift').write_bytes(Path(__file__).with_name('ScriptChecks.swift').read_bytes())
(sources / 'CanvasChecks.swift').write_bytes(Path(__file__).with_name('CanvasChecks.swift').read_bytes())
(sources / 'SettingsChecks.swift').write_bytes(Path(__file__).with_name('SettingsChecks.swift').read_bytes())
(sources / 'UsageChecks.swift').write_bytes(Path(__file__).with_name('UsageChecks.swift').read_bytes())
(sources / 'ConversationChecks.swift').write_bytes(Path(__file__).with_name('ConversationChecks.swift').read_bytes())
(sources / 'AttachmentChecks.swift').write_bytes(Path(__file__).with_name('AttachmentChecks.swift').read_bytes())
(sources / 'MemoryEditingChecks.swift').write_bytes(Path(__file__).with_name('MemoryEditingChecks.swift').read_bytes())
(sources / 'ResearchChecks.swift').write_bytes(Path(__file__).with_name('ResearchChecks.swift').read_bytes())
(generated / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ControllerHarness", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "ControllerHarness", dependencies: [.product(name: "OpenWeightsCore", package: "Product")])])
''')
swift = subprocess.check_output(['swift', '--version'], stderr=subprocess.STDOUT, text=True).strip()
identity = hashlib.sha256(json.dumps({'sources': hashes, 'swift': swift}, sort_keys=True).encode()).hexdigest()[:12]
output = root / f'Results/controller-memory-agent-host-{identity}.json'
with (root / '.build/controller-harness.log').open('w') as log:
    result = subprocess.run(['swift', 'run', '--package-path', str(generated), '--scratch-path', str(root / '.build/controller-harness-build'),
                             '-c', 'release', 'ControllerHarness', str(output)], stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    raise SystemExit(f'Controller checks failed. Inspect {root / ".build/controller-harness.log"}')
assert hashes == {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}, 'Source changed during host validation.'
proof = json.loads(output.read_text())
proof['compiledSourceSHA256'] = hashes
proof['swift'] = swift
proof['runtimeContractExtractSHA256'] = hashlib.sha256((sources / 'RuntimeContracts.swift').read_bytes()).hexdigest()
output.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
print(f"{len(proof['passedChecks'])} canonical controller checks passed. {output.name}")

#!/usr/bin/env python3
"""Retain source-bound core regression evidence for the discovery cohort."""
import hashlib
import json
import re
import subprocess
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
inputs = [root / 'Package.swift', root / 'Package.resolved', Path(__file__)]
inputs += sorted((root / 'Sources/OpenWeightsCore').glob('*.swift'))
inputs += sorted(p for p in (root / 'Tests/OpenWeightsCoreTests').rglob('*') if p.is_file())
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
before = {str(p.relative_to(root)): digest(p) for p in inputs}
log = root / '.build/discovery-core-source-guarded.log'
with log.open('w') as stream:
    result = subprocess.run(['swift', 'test', '--package-path', str(root)], stdout=stream, stderr=subprocess.STDOUT)
assert result.returncode == 0, log
assert before == {str(p.relative_to(root)): digest(p) for p in inputs}, 'Core source changed during validation.'
passed = re.findall(r"Test Case '(.+)' passed", log.read_text())
assert len(passed) == 170, len(passed)
proof = {'status': 'core-regressions-host-verified', 'testCount': len(passed), 'passedChecks': passed, 'compiledSourceSHA256': before, 'logSHA256': digest(log), 'limitations': ['Host XCTest state, tools, persistence and injected discovery responses. No native adapter, UI, OS scheduling or real discovery request.']}
identity = hashlib.sha256(json.dumps(proof, sort_keys=True).encode()).hexdigest()[:12]
output = root / f'Results/discovery-core-host-{identity}.json'
archive = output.with_name(output.stem + '-sources.zip')
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as snapshot:
    for path in inputs:
        snapshot.write(path, str(path.relative_to(root)))
proof['sourceSnapshot'] = archive.name
output.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
print(output.name, len(passed))

#!/usr/bin/env python3
"""Run the acquisition controls on macOS using exact benchmark source files."""
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ['App/ModelStore.swift', 'App/Cancellation.swift', 'App/BenchmarkRunner.swift',
         'Tests/ModelAcquisitionTests.swift', 'Export/check_model_acquisition.py']


def hashes():
    return {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in FILES}


def main():
    before = hashes()
    identity = hashlib.sha256(json.dumps(before, sort_keys=True).encode()).hexdigest()[:12]
    work = ROOT / '.build' / f'model-acquisition-host-{identity}'
    sources = work / 'Sources/OpenWeightsBench'
    tests = work / 'Tests/OpenWeightsBenchTests'
    sources.mkdir(parents=True, exist_ok=True)
    tests.mkdir(parents=True, exist_ok=True)
    (work / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AcquisitionChecks", platforms: [.macOS(.v13)], targets: [
    .target(name: "OpenWeightsBench"),
    .testTarget(name: "OpenWeightsBenchTests", dependencies: ["OpenWeightsBench"])])
''')
    for name in ['ModelStore.swift', 'Cancellation.swift']:
        shutil.copyfile(ROOT / 'App' / name, sources / name)
    # These declarations have no UIKit dependencies. Extract the actual definitions
    # so the host controls share the production downloader's artifact/error types.
    runner = (ROOT / 'App/BenchmarkRunner.swift').read_text()
    declarations = []
    for name in ['struct ArtifactFile:', 'struct Artifact:', 'enum BenchmarkFailure:']:
        start = runner.index(name)
        end = runner.index('\n}\n', start) + 3
        declarations.append(runner[start:end])
    (sources / 'Types.swift').write_text('import Foundation\n\n' + '\n'.join(declarations))
    shutil.copyfile(ROOT / 'Tests/ModelAcquisitionTests.swift', tests / 'ModelAcquisitionTests.swift')
    result = subprocess.run(['swift', 'test', '--package-path', str(work)], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log = ROOT / '.build' / f'model-acquisition-host-{identity}.log'
    log.write_text(result.stdout)
    print(result.stdout)
    if result.returncode or before != hashes():
        raise SystemExit('Acquisition checks failed or inputs changed during execution.')
    match = re.search(r'Executed (\d+) tests, with 0 failures', result.stdout)
    if not match or int(match.group(1)) != 6:
        raise SystemExit('Expected six executed XCTest acquisition controls.')
    proof = {'schemaVersion': 1, 'sources': before, 'testsPassed': 6, 'testsFailed': 0,
             'scope': 'Injected transport and backoff on macOS. No phone, CDN or cloud inference claim.',
             'swift': subprocess.check_output(['swift', '--version'], text=True).strip(),
             'log': str(log.relative_to(ROOT)), 'logSHA256': hashlib.sha256(log.read_bytes()).hexdigest()}
    destination = ROOT / 'Results' / f'model-acquisition-host-{identity}.json'
    destination.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
    print(destination)


if __name__ == '__main__':
    main()

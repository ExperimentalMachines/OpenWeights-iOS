#!/usr/bin/env python3
"""Bind an XCTest package to its toolchain, inputs and selected tests."""
import argparse
import hashlib
import json
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def inputs(delegates, gguf_only=False):
    files = []
    for folder in ['App', 'Tests', 'Native', 'Resources']:
        files.extend(p for p in (ROOT / folder).rglob('*') if p.is_file())
    if gguf_only:
        files.extend(ROOT / p for p in ['build-gguf.sh', 'project-gguf.yml', 'Export/build_receipt.py',
                                      'package.sh', 'Export/verify_archive.py', 'Study/snapshot_build.py',
                                      'Study/run_local_block.sh', 'Study/collect_local.py', 'Study/older-ios-gguf-addendum.json'])
    else:
        files.extend(ROOT / p for p in ['build-delegates.sh' if delegates else 'build.sh',
                                  'project-delegates.yml' if delegates else 'project.yml',
                                  'Package-delegates.resolved' if delegates else 'Package.resolved'])
    if not delegates:
        files.extend((REPO / 'core/engine/src/main/cpp').glob('engine_session.*'))
        files.extend(REPO / name for name in ['core/engine/src/main/cpp/PatchGGMLGraphOffset.cmake',
                                              'core/engine/src/main/cpp/llama.cpp/ggml/src/ggml.c'])
    return {str(p.relative_to(REPO)): digest(p) for p in sorted(files)}


def targets(plan):
    if 'TestConfigurations' in plan:
        return [t for c in plan['TestConfigurations'] for t in c['TestTargets']]
    return [v for k, v in plan.items() if k != '__xctestrun_metadata__']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['capture', 'stamp', 'check', 'plan'])
    variant = parser.add_mutually_exclusive_group()
    variant.add_argument('--delegates', action='store_true')
    variant.add_argument('--gguf-only', action='store_true')
    parser.add_argument('--expected', type=Path)
    parser.add_argument('--suite', choices=['pilot', 'smoke', 'multi-turn', 'mlx-multi-turn', 'coreml-multi-turn', 'study'], default='pilot')
    parser.add_argument('--firebase', action='store_true')
    parser.add_argument('--scenario', choices=['S1-stable-facts', 'S2-workshop-corrections', 'S3-interruption-recovery'], default='S2-workshop-corrections')
    parser.add_argument('--block', type=int, default=0)
    parser.add_argument('--attempt', type=int, default=0)
    parser.add_argument('--runtime')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.mode == 'capture':
        if args.output is None:
            parser.error('Capture requires --output.')
        args.output.write_text(json.dumps(inputs(args.delegates, args.gguf_only), indent=2, sort_keys=True) + '\n')
        return
    products = ROOT / '.build' / ('DerivedData-gguf16' if args.gguf_only else 'DerivedData-delegates' if args.delegates else 'DerivedData') / 'Build/Products'
    receipt_path = products / 'openweights-build.json'
    if args.mode == 'stamp':
        source_hashes = inputs(args.delegates, args.gguf_only)
        if args.expected and json.loads(args.expected.read_text()) != source_hashes:
            raise SystemExit('Build inputs changed during compilation. Rebuild before stamping.')
        executables = [products / 'Release-iphoneos/OpenWeightsBench.app/OpenWeightsBench',
                       products / 'Release-iphoneos/BenchmarkTests.xctest/BenchmarkTests']
        # Hosted test bundles are installed within the app on some Xcode releases.
        if not executables[1].exists():
            executables[1] = products / 'Release-iphoneos/OpenWeightsBench.app/PlugIns/BenchmarkTests.xctest/BenchmarkTests'
        info = plistlib.loads((products / 'Release-iphoneos/OpenWeightsBench.app/Info.plist').read_bytes())
        receipt = {'schemaVersion': 1, 'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
                   'sdk': subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip(),
                   'deploymentTarget': info['MinimumOSVersion'], 'sources': source_hashes,
                   'executables': {str(p.relative_to(products)): digest(p) for p in executables},
                   'llamaRevision': subprocess.check_output(['git', '-C', str(REPO / 'core/engine/src/main/cpp/llama.cpp'), 'rev-parse', 'HEAD'], text=True).strip() if not args.delegates else None}
        if args.gguf_only:
            build = receipt['xcode'].splitlines()[1].split()[-1]
            native = ROOT / f'.build/native-gguf16-{build}-ninja'
            cache = {line.split('=', 1)[0].split(':', 1)[0]: line.split('=', 1)[1]
                     for line in (native / 'CMakeCache.txt').read_text().splitlines()
                     if '=' in line and not line.startswith(('#', '//'))}
            if cache.get('CMAKE_OSX_DEPLOYMENT_TARGET') != '16.6' or cache.get('OW_GGUF_ONLY') != 'ON':
                raise SystemExit('Native library cache differs from the GGUF-only iOS 16.6 configuration.')
            receipt.update(benchmarkVariant='gguf-ios16.6-v1', sourceInputsBeforeAndAfterCompilationMatch=args.expected is not None,
                           nativeArchives={str(p.relative_to(ROOT)): digest(p) for p in sorted(native.rglob('*.a'))},
                           nativeDeploymentTarget=cache['CMAKE_OSX_DEPLOYMENT_TARGET'], frameworksExcluded=['ExecuTorch', 'MLX'])
        receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    else:
        receipt = json.loads(receipt_path.read_text())
        if receipt['sources'] != inputs(args.delegates, args.gguf_only):
            raise SystemExit('Build inputs changed. Rebuild before packaging.')
        for name, expected in receipt['executables'].items():
            if digest(products / name) != expected:
                raise SystemExit(f'Built executable changed: {name}')
        if args.firebase:
            catalog_path = ROOT / '.build/firebase/versions-2026-10-02.json'
            catalog = json.loads(catalog_path.read_text())
            version = receipt['xcode'].splitlines()[0].split()[1]
            supported = {x for row in catalog for x in row.get('supportedXcodeVersionIds', [])}
            if version not in supported:
                raise SystemExit(f'Xcode {version} is not in the retained Firebase catalog. Rebuild with a supported version.')
        if args.mode == 'plan':
            plans = list(products.glob(f"*_iphoneos{receipt['sdk']}-*.xctestrun"))
            if len(plans) != 1:
                raise SystemExit('Expected exactly one XCTest plan.')
            plan = plistlib.loads(plans[0].read_bytes())
            suites = {
                'pilot': ['testPilotBenchmark'],
                'smoke': ['testFirebaseSmoke', 'testArtifactVerificationRejectsCorruption'],
                'multi-turn': ['testMultiTurnBenchmark', 'testMultiTurnProbeGrading'],
                'mlx-multi-turn': ['testMultiTurnExecuTorchMLX', 'testMultiTurnProbeGrading'],
                'coreml-multi-turn': ['testMultiTurnExecuTorchCoreML', 'testMultiTurnProbeGrading'],
                'study': ['testStudyBlock', 'testMultiTurnProbeGrading']}
            if args.suite in ['mlx-multi-turn', 'coreml-multi-turn'] and not args.delegates:
                raise SystemExit('Selected suite requires --delegates.')
            for target in targets(plan):
                target['OnlyTestIdentifiers'] = ['BenchmarkTests/' + method for method in suites[args.suite]]
                target['ParallelizationEnabled'] = False
                target['TestTimeoutsEnabled'] = True
                if args.suite == 'study':
                    if args.block < 0 or args.attempt < 0:
                        raise SystemExit('Block and attempt must be non-negative.')
                    environment = target.setdefault('EnvironmentVariables', {})
                    environment.update(OW_STUDY_BLOCK=str(args.block), OW_STUDY_ATTEMPT=str(args.attempt), OW_STUDY_SCENARIO=args.scenario)
                    if args.runtime:
                        environment['OW_STUDY_RUNTIME'] = args.runtime
                target['DefaultTestExecutionTimeAllowance'] = 2400 if args.suite == 'coreml-multi-turn' or args.runtime == 'ExecuTorch Core ML' else 900
                target['MaximumTestExecutionTimeAllowance'] = target['DefaultTestExecutionTimeAllowance']
            args.output.write_bytes(plistlib.dumps(plan))
    print(receipt_path)


if __name__ == '__main__':
    main()

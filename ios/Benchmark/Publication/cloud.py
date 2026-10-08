#!/usr/bin/env python3
"""Prepare and collect the two-job Firebase publication pilot. Never submits jobs."""
import argparse
import copy
import csv
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import zipfile

import benchmark

ROOT = benchmark.ROOT


def cloud_plan(base, artifact, workload, runtime):
    plan = copy.deepcopy(base)
    target = benchmark.targets(plan)[0]
    target.update(OnlyTestIdentifiers=['BenchmarkTests/testPublicationCloudConversation'],
                  ParallelizationEnabled=False, InProcessParallelizationEnabled=False,
                  TestTimeoutsEnabled=True, DefaultTestExecutionTimeAllowance=600,
                  MaximumTestExecutionTimeAllowance=600, UserAttachmentLifetime='keepAlways')
    env = target.setdefault('EnvironmentVariables', {})
    for key in list(env):
        if key.startswith(('OW_STUDY_', 'OW_PUBLICATION_')):
            del env[key]
    env.update(OW_PUBLICATION_ARTIFACT=json.dumps(artifact, separators=(',', ':')),
               OW_PUBLICATION_WORKLOAD=json.dumps(workload, separators=(',', ':')),
               OW_PUBLICATION_RUNTIME=runtime, OW_PUBLICATION_REPETITION='0')
    for name in ['TestHostPath', 'TestBundlePath', 'DependentProductPaths']:
        values = target.get(name, [])
        for value in values if isinstance(values, list) else [values]:
            if not value.startswith(('__TESTROOT__/', '__TESTHOST__/')) or '..' in Path(value).parts:
                raise ValueError('Expected portable XCTest paths, not local absolute paths.')
    return plan


def prepare(folder, catalog):
    products = ROOT / '.build/DerivedData-gguf16/Build/Products'
    subprocess.run(['python3', str(ROOT / 'Export/build_receipt.py'), 'check', '--gguf-only'], check=True)
    receipt = json.loads((products / 'openweights-build.json').read_text())
    version = receipt['xcode'].splitlines()[0].split()[1]
    models = json.loads((catalog / 'models.json').read_text())
    versions = json.loads((catalog / 'versions.json').read_text())
    device = next(m for m in models if m['id'] == 'iphone16pro')
    os_version = next(v for v in versions if v['id'] == '18.3')
    if '18.3' not in device['supportedVersionIds'] or version not in os_version['supportedXcodeVersionIds']:
        raise ValueError('Selected cloud device/toolchain no longer matches the catalog.')
    if subprocess.check_output(['xcodebuild', '-version'], text=True).strip() != receipt['xcode']:
        raise ValueError('Select the signed build toolchain with DEVELOPER_DIR.')
    app = products / 'Release-iphoneos/OpenWeightsBench.app'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app / 'PlugIns/BenchmarkTests.xctest')], check=True)
    manifest = json.loads(Path(__file__).with_name('comparison-models.json').read_text())
    artifact = next(a for a in benchmark.validate_manifest(manifest) if a['id'] == 'lfm2.5-1.2b-instruct')
    workload = next(w for w in json.loads((ROOT / 'Resources/study-workloads.json').read_text()) if w['id'] == 'S1-stable-facts')
    plans = list(products.glob('*.xctestrun'))
    if len(plans) != 1:
        raise ValueError('Expected one base XCTest plan.')
    base = plistlib.loads(plans[0].read_bytes())
    if len(benchmark.targets(base)) != 1 or receipt['benchmarkVariant'] != 'gguf-ios16.6-v1':
        raise ValueError('Use the GGUF-only single target build.')
    folder.mkdir(parents=True, exist_ok=False)
    benchmark.save(folder / 'models.json', dict(upstream=manifest['upstream'], artifacts=[artifact]))
    benchmark.save(folder / 'workload.json', workload)
    benchmark.save(folder / 'protocol.json', dict(id=benchmark.PROTOCOL, repetitions=1, turns=6,
        contextTokens=2048, maxOutputTokens=64, minimumThroughputOutputTokens=8,
        purpose='Cloud delivery pilot; not three-repetition study', acquisition='Before inference timing inside each fresh execution',
        automaticRetries=0, timeoutSecondsPerJob=600))
    shutil.copyfile(products / 'openweights-build.json', folder / 'build-receipt.json')
    for name in ['models.json', 'versions.json']:
        shutil.copyfile(catalog / name, folder / ('firebase-' + name))
    for name in ['cloud.py', 'benchmark.py', 'archive.py', 'test_cloud.py']:
        shutil.copyfile(Path(__file__).with_name(name), folder / name)
    for name, expected in receipt['sources'].items():
        source = ROOT.parents[1] / name
        if benchmark.digest(source) != expected:
            raise ValueError('Compiled source changed: ' + name)
        destination = folder / 'sources' / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    files = [p for p in sorted((products / 'Release-iphoneos').rglob('*')) if p.is_file()]
    if any(p.is_symlink() for p in (products / 'Release-iphoneos').rglob('*')):
        raise ValueError('Inspect product symlinks before packaging.')
    records = []
    for n, runtime in enumerate(benchmark.RUNTIMES):
        plan = cloud_plan(base, artifact, workload, runtime)
        name = runtime.split()[-1].lower()
        plan_path = folder / (name + '.xctestrun')
        plan_path.write_bytes(plistlib.dumps(plan))
        package = folder / ('OpenWeightsPublication-' + name + '.zip')
        members = {str(p.relative_to(products)): benchmark.digest(p) for p in files}
        with zipfile.ZipFile(package, 'x', zipfile.ZIP_DEFLATED) as bundle:
            for p in files:
                bundle.write(p, str(p.relative_to(products)))
            bundle.write(plan_path, plan_path.name)
        with zipfile.ZipFile(package) as bundle:
            if bundle.testzip() is not None:
                raise ValueError('Archive CRC mismatch.')
            import hashlib
            if any(hashlib.sha256(bundle.read(key)).hexdigest() != value for key, value in members.items()):
                raise ValueError('Archive products differ from the signed build.')
            if bundle.read(plan_path.name) != plan_path.read_bytes():
                raise ValueError('Archive plan changed.')
        records.append(dict(stage='measure', model=artifact['id'], runtime=runtime, repetition=0,
            plan=plan_path.name, planSHA256=benchmark.digest(plan_path), package=package.name,
            packageSHA256=benchmark.digest(package), packageBytes=package.stat().st_size, status='pending'))
    benchmark.save(folder / 'index.json', dict(protocol=benchmark.PROTOCOL, status='cloud-pilot-prepared-not-submitted', records=records))
    benchmark.save(folder / 'submission-proposal.json', dict(device='iphone16pro', catalogIOS='18.3', xcode=version,
        jobs=2, requests=12, timeoutSecondsPerJob=600, primaryExecutionEstimateUSDWithoutFreeAllowance=1.67,
        freeAllowanceRemaining='unverified', ancillaryAndInfrastructureRetryCharges='unverified',
        publicPublication='not-authorized', paidSubmission='requires-explicit-approval',
        commands=[['gcloud','firebase','test','ios','run','--test',str(folder / r['package']),
                  '--device','model=iphone16pro,version=18.3,locale=en_US,orientation=portrait',
                  '--xcode-version',version,'--timeout','10m','--num-flaky-test-attempts','0','--async'] for r in records]))
    print('Prepared two signed portable packages; no cloud upload or execution.')


def collect(folder, directories, statuses):
    index = json.loads((folder / 'index.json').read_text())
    if any(r['status'] != 'pending' for r in index['records']):
        raise ValueError('Never overwrite a collected attempt.')
    for n, (directory, status, record) in enumerate(zip(directories, statuses, index['records'])):
        attachments = folder / f'{n:03d}-attachments'
        shutil.copytree(directory, attachments)
        artifact = json.loads((folder / 'models.json').read_text())['artifacts'][0]
        file = artifact['files'][0]
        events = []
        for path in attachments.rglob('*.json'):
            value = json.loads(path.read_text())
            if isinstance(value, list):
                events.extend(v for v in value if isinstance(v, dict) and 'outcome' in v)
        verified = any(e.get('artifactID') == artifact['id'] and e.get('file') == file['file']
                       and e.get('receivedFileBytes') == file['bytes']
                       and e.get('outcome') in ['cache-verified', 'download-verified'] for e in events)
        record.update(nativeStatus=status, acquisitionVerified=verified,
                      status='passed' if status == 'passed' and verified else 'failed')
    index['status'] = 'cloud-pilot-collected'
    benchmark.save(folder / 'index.json', index)
    benchmark.summarize(folder)
    summary = json.loads((folder / 'summary.json').read_text())
    for row in summary['rows']:
        row.update(plannedConversations=1, plannedSamples=6, plannedProbes=3)
    complete = all(r['completedConversations'] == 1 for r in summary['rows'])
    terminal = 'cloud-pilot-complete' if complete else 'cloud-pilot-incomplete'
    summary.update(status=terminal, deliveryPilot=True)
    summary['notes'].append('One repetition per backend validates cloud delivery only. Acquisition occurs in each job before inference timing. Provider conditions form a separate device/OS cohort.')
    benchmark.save(folder / 'summary.json', summary)
    with (folder / 'summary.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(summary['rows'][0]))
        writer.writeheader(); writer.writerows(summary['rows'])
    index = json.loads((folder / 'index.json').read_text());index['status'] = terminal
    benchmark.save(folder / 'index.json', index)
    return complete


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('prepare');p.add_argument('folder', type=Path);p.add_argument('--catalog', type=Path, required=True)
    c = sub.add_parser('collect');c.add_argument('folder', type=Path);c.add_argument('--cpu-attachments', type=Path, required=True);c.add_argument('--metal-attachments', type=Path, required=True)
    c.add_argument('--cpu-status', choices=['passed','failed'], required=True);c.add_argument('--metal-status', choices=['passed','failed'], required=True)
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare(args.folder.resolve(), args.catalog.resolve())
    else:
        raise SystemExit(0 if collect(args.folder.resolve(), [args.cpu_attachments, args.metal_attachments], [args.cpu_status,args.metal_status]) else 1)


if __name__ == '__main__':
    main()

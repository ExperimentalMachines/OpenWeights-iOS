#!/usr/bin/env python3
"""Retain a study report and sanitized XCTest/build evidence without copying device IDs."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from snapshot_build import snapshot


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('bundle', type=Path)
    variant = parser.add_mutually_exclusive_group()
    variant.add_argument('--delegates', action='store_true')
    variant.add_argument('--gguf-only', action='store_true')
    parser.add_argument('--unplugged-confirmed', action='store_true')
    parser.add_argument('--recovered-report', type=Path)
    parser.add_argument('--retained-execution', type=Path,
                        help='Collect a verified immutable package run using its retained execution receipt, not current sources.')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    bundle = args.bundle.resolve()
    attachments = bundle.with_name(bundle.stem + '-attachments')
    summary = json.loads(subprocess.check_output([
        'xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
        '--path', str(bundle), '--format', 'json'], text=True))
    derived = 'DerivedData-gguf16' if args.gguf_only else 'DerivedData-delegates' if args.delegates else 'DerivedData'
    execution = None
    if args.retained_execution:
        execution = json.loads(args.retained_execution.read_text())
        if execution.get('resultBundle') != bundle.name or execution.get('status') != 'native-execution-terminal-results-await-inspection':
            raise SystemExit('Retained execution receipt does not identify this completed test operation.')
        for name, hash_key in [('archive', 'archiveSHA256'), ('receipt', 'receiptSHA256'), ('sourceSnapshot', 'sourceSnapshotSHA256')]:
            filename = execution[name]
            if Path(filename).name != filename:
                raise SystemExit('Retained evidence must name a file inside Results.')
            if hashlib.sha256((root / 'Results' / filename).read_bytes()).hexdigest() != execution[hash_key]:
                raise SystemExit(f'Retained evidence changed: {filename}')
        receipt = json.loads((root / 'Results' / execution['receipt']).read_text())
        if execution['executablesBefore'] != receipt['executables'] or execution['executablesAfter'] != receipt['executables']:
            raise SystemExit('Executed binary hashes do not match the retained package receipt.')
    else:
        receipt = json.loads((root / '.build' / derived / 'Build/Products/openweights-build.json').read_text())
    reports = []
    if args.recovered_report:
        reports.append((args.recovered_report, json.loads(args.recovered_report.read_text())))
    for path in attachments.glob('*.json'):
        data = json.loads(path.read_text())
        if isinstance(data, dict) and data.get('purpose') == 'repeated-conversation-artifact-study':
            reports.append((path, data))
    if len(reports) != 1:
        raise SystemExit(f'Expected one study report, found {len(reports)}. Bundle retained: {bundle.name}')
    path, report = reports[0]
    metadata = report['study']
    if execution:
        command = ['python3', str(root / 'Export/verify_archive.py'), str(root / 'Results' / execution['archive']),
                   '--receipt', str(root / 'Results' / execution['receipt']),
                   '--sources', str(root / 'Results' / execution['sourceSnapshot']), '--suite', 'study',
                   '--scenario', metadata['scenario'], '--block', str(metadata['block']),
                   '--attempt', str(metadata.get('attempt', 0))]
        if metadata.get('runtimeFilter'):
            command.extend(['--runtime', metadata['runtimeFilter']])
        subprocess.run(command, check=True)
    stem = f"{report['device']}-study-{metadata['scenario']}-block{metadata['block']}-attempt{metadata.get('attempt', 0)}-{report['runID']}"
    raw = root / 'Results' / (stem + '.json')
    raw.write_bytes(path.read_bytes())
    proof = {
        'buildReceipt': receipt,
        'collectorSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'sourceSnapshot': ({'file': execution['sourceSnapshot'], 'sha256': execution['sourceSnapshotSHA256']}
                           if execution else snapshot(args.delegates, args.gguf_only) if not args.recovered_report else None),
        'executionXcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
        'rawResultsFile': raw.name,
        'rawResultsSHA256': hashlib.sha256(raw.read_bytes()).hexdigest(),
        'resultBundle': bundle.name,
        'testSummary': {key: summary.get(key) for key in ['result', 'totalTestCount', 'passedTests', 'failedTests', 'skippedTests', 'startTime', 'finishTime']},
        'unpluggedConfirmedByUser': args.unplugged_confirmed,
        'checkpointRecoveredFromDevice': args.recovered_report is not None,
    }
    if execution:
        proof['retainedPackageExecution'] = {'file': args.retained_execution.name,
                                           'sha256': hashlib.sha256(args.retained_execution.read_bytes()).hexdigest(),
                                           'archive': execution['archive'], 'archiveSHA256': execution['archiveSHA256'],
                                           'planUnchanged': execution['planUnchanged']}
    raw.with_name(stem + '-source.json').write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'file': raw.name, 'scenario': metadata['scenario'], 'block': metadata['block'],
                      'completed': report['completed'], 'testResult': summary.get('result')}))


if __name__ == '__main__':
    main()

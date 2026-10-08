#!/usr/bin/env python3
"""Retain a completed migration benchmark with exact inputs and a checked manifest."""
import argparse
import hashlib
import json
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ROOT = REPO / 'ios/Benchmark'
sys.path.insert(0, str(ROOT / 'Export'))
from build_receipt import digest, inputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('label')
    parser.add_argument('--delegates', action='store_true')
    args = parser.parse_args()
    if Path(args.label).name != args.label or not args.label.startswith('migration-'):
        raise SystemExit('Expected a migration run label, not a path.')
    results = ROOT / 'Results'
    execution_path = results / (args.label + '-execution.json')
    execution = json.loads(execution_path.read_text())
    if execution['status'] != 'native-execution-terminal-results-await-inspection':
        raise SystemExit('The run is not terminal.')
    if execution['exitCode'] != 0 or execution['attachmentExportExitCode'] != 0:
        raise SystemExit('This validation proof requires passing execution and attachment export.')
    derived = 'DerivedData-delegates' if args.delegates else 'DerivedData'
    products = ROOT / '.build' / derived / 'Build/Products'
    receipt_path = products / 'openweights-build.json'
    receipt = json.loads(receipt_path.read_text())
    if digest(receipt_path) != execution['receiptSHA256'] or inputs(args.delegates) != receipt['sources']:
        raise SystemExit('Compiled inputs or receipt changed.')
    if execution['executablesBefore'] != receipt['executables'] or execution['executablesAfter'] != receipt['executables']:
        raise SystemExit('Executed binary identities differ from the receipt.')
    for name, expected in receipt['executables'].items():
        if digest(products / name) != expected:
            raise SystemExit('Active compiled executable changed: ' + name)
    summary_path = results / (args.label + '-summary.json')
    summary = json.loads(summary_path.read_text())
    if (summary.get('passedTests'), summary.get('failedTests'), summary.get('skippedTests')) != (3, 0, 0):
        raise SystemExit('Expected three selected passing validation methods without skips.')
    attachments = results / (args.label + '-attachments')
    reports = []
    for path in attachments.glob('*.json'):
        data = json.loads(path.read_text())
        if isinstance(data, dict) and isinstance(data.get('rows'), list):
            reports.append((path, data))
    if len(reports) != 1:
        raise SystemExit('Expected exactly one benchmark report.')
    raw_path, raw = reports[0]
    expected_rows = 2 if args.delegates else 5
    if not raw.get('completed') or len(raw['rows']) != expected_rows:
        raise SystemExit('Incomplete or unexpected runtime configuration set.')
    for row in raw['rows']:
        if row.get('error') or not row.get('cancellationPassed') or len(row['samples']) != 9:
            raise SystemExit('A runtime did not complete its nine-request/cancellation validation.')
    log_path = ROOT / '.build' / (args.label + '.log')
    plan_path = Path(execution['command'][execution['command'].index('-xctestrun') + 1])
    if digest(log_path) != execution['nativeLogSHA256'] or digest(plan_path) != execution['planSHA256']:
        raise SystemExit('Native log or selected plan changed.')
    files = [execution_path, summary_path, receipt_path, log_path, plan_path,
             Path(__file__), ROOT / '.build' / ('run-migration-delegates.py' if args.delegates else 'run-migration-benchmark.py')]
    files.extend(REPO / name for name in receipt['sources'])
    files.extend(p for folder in [attachments, results / (args.label + '.xcresult')]
                 for p in folder.rglob('*') if p.is_file())
    files = sorted(set(files))
    manifest = {}
    archive_path = results / (args.label + '-proof.zip')
    if archive_path.exists():
        raise SystemExit('Refusing to overwrite completed evidence: ' + archive_path.name)
    with zipfile.ZipFile(archive_path, 'x', zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            if path.is_symlink():
                raise RuntimeError('Unexpected symbolic link in evidence: ' + str(path))
            relative = str(path.relative_to(REPO))
            data = path.read_bytes()
            manifest[relative] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
            archive.writestr(relative, data)
        archive.writestr('manifest.json', json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    with zipfile.ZipFile(archive_path) as archive:
        if archive.testzip() is not None:
            raise RuntimeError('Evidence ZIP CRC check failed.')
        for name, expected in manifest.items():
            data = archive.read(name)
            if len(data) != expected['bytes'] or hashlib.sha256(data).hexdigest() != expected['sha256']:
                raise RuntimeError('Evidence manifest mismatch: ' + name)
    proof = {'schemaVersion': 1, 'status': 'selected-native-migration-validation-verified',
             'label': args.label, 'testSummary': execution['testSummary'],
             'runtimeConfigurations': [row['engine'] for row in raw['rows']],
             'requests': sum(len(row['samples']) for row in raw['rows']),
             'rawReport': str(raw_path.relative_to(REPO)), 'rawReportSHA256': digest(raw_path),
             'archive': {'file': archive_path.name, 'bytes': archive_path.stat().st_size,
                         'sha256': digest(archive_path), 'entries': manifest},
             'limits': ['Selected migration methods do not establish full Android parity.',
                        'This pilot is not a primary repeated-study block.',
                        'Signed products remain active locally and are identified by receipt hashes.']}
    proof_path = results / (args.label + '-verification.json')
    proof_path.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'proof': str(proof_path.relative_to(REPO)), 'archive': archive_path.name,
                      'bytes': archive_path.stat().st_size, 'requests': proof['requests']}))


if __name__ == '__main__':
    main()

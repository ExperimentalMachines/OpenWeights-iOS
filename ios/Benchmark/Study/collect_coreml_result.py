#!/usr/bin/env python3
"""Validate a completed Firebase Core ML S1 result against its approved inputs.

This does not submit tests, download results, grade answers or modify failed
native attachments. Download all provider attempts before invoking it.
"""
import argparse
import base64
import hashlib
import json
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path, algorithm='sha256'):
    value = hashlib.new(algorithm)
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            value.update(chunk)
    return value


def without_nulls(value):
    if isinstance(value, dict):
        return {k: without_nulls(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [without_nulls(v) for v in value]
    return value


def validate_report(report, summary, block, attempt, scenario, artifact, model_assets):
    """Keep answer correctness separate from protocol and acquisition integrity."""
    require(report.get('purpose') == 'repeated-conversation-artifact-study', 'Wrong report purpose')
    require(report.get('completed') is True, 'Incomplete report')
    require(report.get('study') == {
        'attempt': attempt, 'block': block,
        'protocolID': 'openweights-ios-artifact-study-v1',
        'runtimeOrder': ['ExecuTorch Core ML'], 'scenario': 'S1-stable-facts'
    }, 'Wrong study block, attempt, scenario or runtime')
    require(report.get('device') == 'iPhone17,1', 'Unexpected physical model')
    require(report.get('contextTokens') == 2048 and report.get('maxOutputTokens') == 64,
            'Changed context or output limit')
    require(report.get('lowPowerMode') is False, 'Low Power Mode violates the protocol control')
    require(without_nulls(report.get('multiTurnWorkload')) == without_nulls(scenario),
            'Workload differs from the exact packaged fixture')
    require(len(summary.get('devicesAndConfigurations', [])) == 1, 'Ambiguous native device evidence')
    device = summary['devicesAndConfigurations'][0]['device']
    require(device.get('modelName') == 'iPhone 16 Pro' and device.get('platform') == 'iOS',
            'Native summary identifies another device')
    os_text = f"Version {device['osVersion']} (Build {device['osBuildNumber']})"
    require(report.get('operatingSystem') == os_text, 'Raw OS differs from the native result')
    require(summary.get('result') == 'Passed' and summary.get('passedTests') == 2
            and summary.get('failedTests') == 0 and summary.get('skippedTests') == 0
            and summary.get('totalTestCount') == 2,
            'Both expected native methods must pass without skips')
    require(len(report.get('rows', [])) == 1, 'Expected one isolated runtime row')
    row = report['rows'][0]
    require(row.get('engine') == 'ExecuTorch Core ML' and row.get('phase') == 'complete'
            and not row.get('error'), 'Runtime row did not complete successfully')
    require(without_nulls(row.get('artifact')) == without_nulls(artifact),
            'Artifact identity, revision, files or hashes differ from the package')
    files = {f['file']: f for f in artifact['files']}
    require(len(files) == len(artifact['files']), 'Duplicate artifact file')
    for name, item in files.items():
        require(model_assets.get('Models/coreml/' + name) == item['sha256'],
                'Artifact file differs from the signed build receipt')
    acquisitions = report.get('acquisitions', [])
    require(len(acquisitions) == len(files), 'Missing or duplicate acquisition event')
    require({a.get('file') for a in acquisitions} == set(files), 'Wrong acquired files')
    for event in acquisitions:
        require(event.get('artifactID') == 'coreml' and event.get('outcome') == 'bundle-verified'
                and event.get('attempt') == 0
                and event.get('receivedFileBytes') == files[event['file']]['bytes'],
                'Bundled acquisition did not verify the exact file size')
    samples = row.get('samples', [])
    require(len(samples) == 6 and [s.get('turn') for s in samples] == list(range(1, 7)),
            'Expected exactly six ordered conversation turns')
    messages = [{'role': 'system', 'content': scenario['system']}]
    for sample, turn in zip(samples, scenario['turns']):
        require(sample.get('workload') == 'multi-turn'
                and sample.get('cachePolicy') == 'rebuild-each-turn'
                and sample.get('cachedTokens') == 0
                and sample.get('conversationID') == 'S1-stable-facts'
                and sample.get('repetition') == block, 'Wrong request or cache metadata')
        user = (turn.get('padding') or '') * (turn.get('paddingRepeats') or 0) + turn['user']
        messages.append({'role': 'user', 'content': user})
        require(sample.get('messages') == messages, 'Prompt or carried assistant history differs')
        require(isinstance(sample.get('output'), str), 'Missing recorded assistant output')
        messages.append({'role': 'assistant', 'content': sample['output']})
    return os_text


def verify_object(path, metadata):
    require(int(metadata['size']) == path.stat().st_size, 'Uploaded object size mismatch')
    md5 = base64.b64encode(digest(path, 'md5').digest()).decode()
    require(metadata['md5_hash'] == md5, 'Uploaded object MD5 mismatch')
    return {k: metadata[k] for k in ['storage_url', 'size', 'generation', 'md5_hash', 'crc32c_hash']}


def require_new_source_proof(path):
    require(not path.exists(), 'Existing source proof must be inspected rather than overwritten')


def native_directory(path, root):
    resolved = path.resolve()
    require(resolved.is_relative_to((root / 'Results').resolve()),
            'Native evidence must be inside the benchmark Results directory')
    return resolved


def retain_snapshot(path, data):
    if path.exists():
        require(path.read_bytes() == data, 'Existing evidence snapshot differs')
    else:
        with path.open('xb') as stream:
            stream.write(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preflight', type=Path, required=True)
    parser.add_argument('--submission', type=Path, required=True)
    parser.add_argument('--matrix-file', type=Path, required=True)
    parser.add_argument('--native-dir', type=Path, required=True)
    parser.add_argument('--package-object', type=Path, required=True)
    parser.add_argument('--plan-object', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    args.native_dir = native_directory(args.native_dir, root)
    preflight = json.loads(args.preflight.read_text())
    submission = json.loads(args.submission.read_text())
    matrix = json.loads(args.matrix_file.read_text())
    require(preflight['scenario'] == 'S1-stable-facts'
            and preflight['runtime'] == 'ExecuTorch Core ML', 'Only isolated Core ML S1 is supported')
    require(submission.get('matrixState') == 'FINISHED'
            and submission.get('submissionCLIExitCode') == 0
            and matrix.get('state') == 'FINISHED'
            and matrix.get('testMatrixId') == submission.get('matrixID'),
            'Matrix or submission is not terminal or belongs to another job')
    require(submission.get('authorization') == preflight.get('authorization')
            and submission.get('command') == preflight.get('command')
            and submission.get('package') == preflight.get('package'), 'Approved inputs differ')
    require(bool(submission.get('authorization', {}).get('questionItemID')), 'Missing job approval')
    package = preflight['package']
    archive = root / 'Results' / package['file']
    receipt_path = root / 'Results' / package['buildReceipt']['file']
    sources_path = root / 'Results' / package['sourceSnapshot']['file']
    for path, expected in [(archive, package['sha256']),
                           (receipt_path, package['buildReceipt']['sha256']),
                           (sources_path, package['sourceSnapshot']['sha256'])]:
        require(digest(path).hexdigest() == expected, 'Approved input hash mismatch: ' + path.name)
    receipt = json.loads(receipt_path.read_text())
    command = [sys.executable, str(root / 'Export/verify_archive.py'), str(archive),
               '--receipt', str(receipt_path), '--sources', str(sources_path), '--suite', 'study',
               '--scenario', preflight['scenario'], '--block', str(preflight['block']),
               '--attempt', str(preflight['attempt']), '--runtime', preflight['runtime']]
    separate_plan = package['archiveVerifierOutput'].get('separatePlan')
    if separate_plan:
        require(args.plan_object is not None, 'Separate plan requires its uploaded object metadata')
        plan_path = root / 'Results' / separate_plan['file']
        require(digest(plan_path).hexdigest() == separate_plan['sha256'], 'Separate plan hash mismatch')
        command += ['--xctestrun-file', str(plan_path)]
    else:
        require(args.plan_object is None, 'Unexpected separate plan evidence')
    archive_verification = json.loads(subprocess.check_output(command, text=True))
    require(archive_verification == package['archiveVerifierOutput'], 'Archive verification differs')
    uploaded_package = verify_object(archive, json.loads(args.package_object.read_text()))
    uploaded_plan = (verify_object(plan_path, json.loads(args.plan_object.read_text()))
                     if separate_plan else None)
    spec = matrix['testSpecification']
    require(spec.get('testTimeout') == '2700s'
            and spec.get('iosXcTest', {}).get('xcodeVersion') == '26.2',
            'Provider timeout or Xcode differs')
    require(spec['iosXcTest']['testsZip']['gcsPath']
            == uploaded_package['storage_url'].split('#')[0], 'Package metadata belongs to another object')
    if uploaded_plan:
        require(spec['iosXcTest']['xctestrun']['gcsPath']
                == uploaded_plan['storage_url'].split('#')[0], 'Plan metadata belongs to another object')
    else:
        require('xctestrun' not in spec['iosXcTest'], 'Provider unexpectedly overrides the embedded plan')
    summary = json.loads((args.native_dir / 'summary.json').read_text())
    methods = ET.parse(args.native_dir / 'test_result_0.xml').getroot().findall('.//testcase')
    require(len(methods) == 2 and {t.attrib['name'] for t in methods}
            == {'testStudyBlock', 'testMultiTurnProbeGrading'}, 'Unexpected native method selection')
    require(all(not any(t.find(tag) is not None for tag in ['failure', 'error', 'skipped'])
                for t in methods), 'Native XML reports failure or skip')
    reports = []
    for path in (args.native_dir / 'attachments').glob('*.json'):
        candidate = json.loads(path.read_text())
        if isinstance(candidate, dict) and candidate.get('purpose') == 'repeated-conversation-artifact-study':
            reports.append((path, candidate))
    require(len(reports) == 1, 'Expected exactly one native study attachment')
    attachment, report = reports[0]
    with zipfile.ZipFile(archive) as z:
        base = 'Release-iphoneos/OpenWeightsBench.app/'
        workloads = json.loads(z.read(base + 'study-workloads.json'))
        scenarios = workloads if isinstance(workloads, list) else workloads['scenarios']
        scenario = next(s for s in scenarios if s['id'] == preflight['scenario'])
        manifest = json.loads(z.read(base + 'model-manifest-delegates.json'))
        artifact = next(a for a in manifest['artifacts'] if a['id'] == 'coreml')
        embedded_plan = next(n for n in z.namelist() if n.endswith('.xctestrun'))
        plan_bytes = plan_path.read_bytes() if separate_plan else z.read(embedded_plan)
    plan = plistlib.loads(plan_bytes)
    require(plan['BenchmarkTests']['EnvironmentVariables']['OW_STUDY_BLOCK']
            == str(preflight['block']), 'Selected plan has another block')
    actual_os = validate_report(report, summary, preflight['block'], preflight['attempt'],
                                scenario, artifact, receipt['modelAssets'])
    raw = root / 'Results' / (f"iPhone17,1-study-S1-stable-facts-coreml-block{preflight['block']}"
                              f"-attempt{preflight['attempt']}-{report['runID']}.json")
    source_proof = raw.with_name(raw.stem + '-source.json')
    require_new_source_proof(source_proof)
    if raw.exists():
        require(raw.read_bytes() == attachment.read_bytes(), 'Existing raw report differs')
    else:
        raw.write_bytes(attachment.read_bytes())
    submission.update(status='completed-native-results-verified', actualNativeExecutionStartedVerified=True,
                      rawResultsFile=raw.name, rawResultsSHA256=digest(raw).hexdigest(),
                      actualOperatingSystem=actual_os,
                      nativeTestSummary={k: summary[k] for k in
                                         ['result', 'passedTests', 'failedTests', 'skippedTests', 'totalTestCount']})
    args.submission.write_text(json.dumps(submission, indent=2, sort_keys=True) + '\n')
    submission_snapshot = raw.with_name(raw.stem + '-submission.json')
    matrix_snapshot = raw.with_name(raw.stem + '-matrix.json')
    retain_snapshot(submission_snapshot, args.submission.read_bytes())
    retain_snapshot(matrix_snapshot, args.matrix_file.read_bytes())
    proof = {'schemaVersion': 1, 'matrixId': submission['matrixID'],
             'rawResultsFile': raw.name, 'rawResultsSHA256': digest(raw).hexdigest(),
             'buildReceipt': receipt, 'buildReceiptFile': package['buildReceipt'],
             'sourceSnapshot': package['sourceSnapshot'],
             'approvedSubmissionProof': {'file': submission_snapshot.name,
                                         'sha256': digest(submission_snapshot).hexdigest()},
             'terminalMatrixProof': {'file': matrix_snapshot.name,
                                     'sha256': digest(matrix_snapshot).hexdigest()},
             'nativeAttachment': {'file': str(Path('Results') / attachment.relative_to((root / 'Results').resolve())),
                                  'sha256': digest(attachment).hexdigest()},
             'nativeSummary': summary, 'packageSHA256': package['sha256'],
             'selectedPlan': {'file': separate_plan['file'] if separate_plan else embedded_plan,
                              'sha256': hashlib.sha256(plan_bytes).hexdigest()},
             'firebaseUploadedObject': uploaded_package, 'firebaseUploadedSeparatePlan': uploaded_plan,
             'uploadedPackageMatchesLocalMD5AndSize': True,
             'collectionScriptSHA256': digest(Path(__file__)).hexdigest(),
             'limits': ['Cloud charging, ambient temperature and actual invoice are unknown.',
                        'S1 does not exercise cancellation. Answer quality is graded separately.',
                        'The actual OS is recorded for cohort assignment, never assumed from the catalog.',
                        'Input object checksums do not establish post-execution installed binary hashes.',
                        'The original signed cohort is used, not newly rebuilt delegate binaries.']}
    source_proof.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'raw': raw.name, 'actualOS': actual_os,
                      'block': preflight['block'], 'nativeMethods': 2, 'turns': 6}))


if __name__ == '__main__':
    main()

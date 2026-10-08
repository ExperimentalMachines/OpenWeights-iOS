#!/usr/bin/env python3
"""Verify a retained immutable archive against its receipt and source snapshot."""
import argparse
import copy
import hashlib
import json
import plistlib
import zipfile
from pathlib import Path


def digest_stream(stream):
    value = hashlib.sha256()
    for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b''):
        value.update(chunk)
    return value.hexdigest()


def plan_bindings(plan):
    """Keep test hosts, selection, timeouts and every non-study setting fixed."""
    result = copy.deepcopy(plan)
    environment = result['BenchmarkTests'].get('EnvironmentVariables', {})
    for name in ['OW_STUDY_SCENARIO', 'OW_STUDY_BLOCK', 'OW_STUDY_ATTEMPT', 'OW_STUDY_RUNTIME']:
        environment.pop(name, None)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('archive', type=Path)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--sources', type=Path, required=True)
    parser.add_argument('--suite', choices=['smoke', 'study'], default='smoke')
    parser.add_argument('--scenario')
    parser.add_argument('--block', type=int)
    parser.add_argument('--attempt', type=int, default=0)
    parser.add_argument('--runtime')
    parser.add_argument('--xctestrun-file', type=Path,
                        help='Verify a separate study plan against the archive bindings, as supported by Firebase.')
    args = parser.parse_args()
    if args.suite == 'study' and (args.scenario is None or args.block is None):
        parser.error('A study archive requires its scenario and block.')
    if args.xctestrun_file and args.suite != 'study':
        parser.error('A separate plan is supported only for the retained study suite.')
    receipt = json.loads(args.receipt.read_text())
    with zipfile.ZipFile(args.archive) as package:
        for name, expected in receipt['executables'].items():
            with package.open(name) as stream:
                if digest_stream(stream) != expected:
                    raise SystemExit(f'Executable does not match build receipt: {name}')
        plans = [name for name in package.namelist() if name.endswith('.xctestrun')]
        if len(plans) != 1:
            raise SystemExit('Expected exactly one test plan.')
        plan = plistlib.loads(package.read(plans[0]))
        if args.xctestrun_file:
            override = plistlib.loads(args.xctestrun_file.read_bytes())
            if plan_bindings(override) != plan_bindings(plan):
                raise SystemExit('Separate study plan changes test hosts, selection, timeouts or non-study settings.')
            plan = override
        expected_tests = (['BenchmarkTests/testFirebaseSmoke', 'BenchmarkTests/testArtifactVerificationRejectsCorruption']
                          if args.suite == 'smoke' else ['BenchmarkTests/testStudyBlock', 'BenchmarkTests/testMultiTurnProbeGrading'])
        if plan['BenchmarkTests'].get('OnlyTestIdentifiers') != expected_tests:
            raise SystemExit('Archive does not contain the expected isolated suite.')
        if args.suite == 'study':
            environment = plan['BenchmarkTests']['EnvironmentVariables']
            expected = {'OW_STUDY_SCENARIO': args.scenario, 'OW_STUDY_BLOCK': str(args.block),
                        'OW_STUDY_ATTEMPT': str(args.attempt)}
            if args.runtime is not None:
                expected['OW_STUDY_RUNTIME'] = args.runtime
            elif environment.get('OW_STUDY_RUNTIME'):
                raise SystemExit('Archive unexpectedly restricts the runtime.')
            if any(environment.get(key) != value for key, value in expected.items()):
                raise SystemExit('Study plan differs from the requested scenario/block/runtime.')
    with zipfile.ZipFile(args.sources) as sources:
        archived_receipt = json.loads(sources.read('build-receipt.json'))
        if archived_receipt != receipt:
            raise SystemExit('Source snapshot belongs to another build.')
        for name, expected in receipt['sources'].items():
            with sources.open(name) as stream:
                if digest_stream(stream) != expected:
                    raise SystemExit(f'Source snapshot hash mismatch: {name}')
    with args.archive.open('rb') as stream:
        result = {'archive': args.archive.name, 'sha256': digest_stream(stream),
                  'xcode': receipt['xcode'], 'tests': expected_tests}
        if args.xctestrun_file:
            result['separatePlan'] = {'file': args.xctestrun_file.name,
                                     'sha256': hashlib.sha256(args.xctestrun_file.read_bytes()).hexdigest()}
        print(json.dumps(result))


if __name__ == '__main__':
    main()

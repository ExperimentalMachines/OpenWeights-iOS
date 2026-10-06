#!/usr/bin/env python3
"""Verify a retained immutable archive against its receipt and source snapshot."""
import argparse
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
    args = parser.parse_args()
    if args.suite == 'study' and (args.scenario is None or args.block is None):
        parser.error('A study archive requires its scenario and block.')
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
        print(json.dumps({'archive': args.archive.name, 'sha256': digest_stream(stream),
                          'xcode': receipt['xcode'], 'tests': expected_tests}))


if __name__ == '__main__':
    main()

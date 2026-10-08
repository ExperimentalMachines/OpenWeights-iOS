#!/usr/bin/env python3
"""Refresh observed execution state without merging actual OS cohorts."""
import argparse
import json
from collections import defaultdict
from pathlib import Path
from build_cohort import source_cohort


ACTUAL_DEVICE_BY_CATALOG_NAME = {
    'local iPhone 16': 'iPhone17,3',
    'Firebase iPhone 16 Pro': 'iPhone17,1',
    'Firebase iPhone SE 3': 'iPhone14,6',
}


def update(analysis, ledger, results):
    if analysis.get('schemaVersion') != 5:
        raise ValueError('Ledger refresh requires source/build-separated analysis schema 5.')
    records = []
    for source in analysis['sources']:
        path = results / source['file']
        raw = path.read_bytes()
        report = json.loads(raw)
        if report.get('purpose') != 'repeated-conversation-artifact-study':
            continue
        cohort = source_cohort(path, raw)
        if source.get('buildCohortSHA256') != cohort['buildCohortSHA256']:
            raise ValueError('Analysis build cohort differs from retained source proof: ' + path.name)
        study = report['study']
        records.append({**source, **cohort, 'protocolID': study.get('protocolID'), 'device': report['device'], 'operatingSystem': report['operatingSystem'],
                        'contextTokens': report['contextTokens'], 'maxOutputTokens': report['maxOutputTokens'],
                        'scenario': study['scenario'], 'block': study['block'], 'attempt': study.get('attempt', 0),
                        'completed': report['completed'], 'runtimeVersions': report['runtimeVersions'], 'rowStates': [
                            {'runtime': row['engine'], 'phase': row.get('phase'), 'error': row.get('error'),
                             'artifactID': row['artifact']['id'],
                             'artifactHashes': {f['file']: f['sha256'] for f in row['artifact']['files']},
                             'cachePolicies': sorted({s.get('cachePolicy') for s in row['samples'] if s.get('cachePolicy')}),
                             'samples': len(row['samples'])} for row in report['rows']]})
    for cell in ledger['plannedCells']:
        device = ACTUAL_DEVICE_BY_CATALOG_NAME[cell['deviceCatalogName']]
        observed = [r for r in records if r['device'] == device and r['scenario'] == cell['scenario']
                    and any(row['runtime'] == cell['runtime'] for row in r['rowStates'])]
        cohorts = defaultdict(set)
        for r in observed:
            for row in r['rowStates']:
                if r['completed'] and r['attempt'] == 0 and row['runtime'] == cell['runtime'] and row['phase'] == 'complete':
                    identity = {'operatingSystem': r['operatingSystem'], 'artifactID': row['artifactID'],
                                'artifactHashes': row['artifactHashes'], 'runtimeVersions': r['runtimeVersions'],
                                'buildCohortSHA256': r['buildCohortSHA256'],
                                'protocolID': r['protocolID'],
                                'contextTokens': r['contextTokens'], 'maxOutputTokens': r['maxOutputTokens'],
                                'cachePolicies': row['cachePolicies']}
                    cohorts[json.dumps(identity, sort_keys=True)].add(r['block'])
        cell.pop('completeBlocksByActualOS', None)
        cell['completeBlockCohorts'] = [{**json.loads(identity), 'blocks': sorted(blocks)}
                                       for identity, blocks in sorted(cohorts.items())]
        cell['completedPrimaryBlocks'] = max(map(len, cohorts.values()), default=0)
        cell['observedRawFiles'] = [r['file'] for r in observed]
        cell['status'] = 'replication-satisfied' if cell['completedPrimaryBlocks'] >= cell['requiredCompleteIndependentBlocks'] else 'incomplete'
        # Historical infrastructure failures are retained in unavailableExecutions.
        # They do not establish current device availability or erase later reports.
    ledger['records'] = records
    ledger['analysisGradingVersion'] = analysis['gradingVersion']
    return ledger


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('analysis', type=Path)
    parser.add_argument('ledger', type=Path)
    parser.add_argument('--results', type=Path, default=Path('Results'))
    args = parser.parse_args()
    result = update(json.loads(args.analysis.read_text()), json.loads(args.ledger.read_text()), args.results)
    args.ledger.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(f"{len(result['records'])} retained reports, "
          f"{sum(c['status'] == 'replication-satisfied' for c in result['plannedCells'])} replicated cells")


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Refresh observed execution state without merging actual OS cohorts."""
import argparse
import json
from collections import defaultdict
from pathlib import Path


def update(analysis, ledger, results):
    records = []
    for source in analysis['sources']:
        report = json.loads((results / source['file']).read_text())
        study = report['study']
        records.append({**source, 'device': report['device'], 'operatingSystem': report['operatingSystem'],
                        'scenario': study['scenario'], 'block': study['block'], 'attempt': study.get('attempt', 0),
                        'completed': report['completed'], 'runtimeVersions': report['runtimeVersions'], 'rowStates': [
                            {'runtime': row['engine'], 'phase': row.get('phase'), 'error': row.get('error'),
                             'artifactID': row['artifact']['id'],
                             'artifactHashes': {f['file']: f['sha256'] for f in row['artifact']['files']},
                             'samples': len(row['samples'])} for row in report['rows']]})
    for cell in ledger['plannedCells']:
        device = 'iPhone17,3' if cell['deviceCatalogName'] == 'local iPhone 16' else 'iPhone17,1'
        # SE executions have no raw inference report. Do not attribute Pro reports to them.
        if 'SE' in cell['deviceCatalogName']:
            observed = []
        else:
            observed = [r for r in records if r['device'] == device and r['scenario'] == cell['scenario']
                        and any(row['runtime'] == cell['runtime'] for row in r['rowStates'])]
        cohorts = defaultdict(set)
        for r in observed:
            for row in r['rowStates']:
                if r['completed'] and r['attempt'] == 0 and row['runtime'] == cell['runtime'] and row['phase'] == 'complete':
                    identity = {'operatingSystem': r['operatingSystem'], 'artifactID': row['artifactID'],
                                'artifactHashes': row['artifactHashes'], 'runtimeVersions': r['runtimeVersions']}
                    cohorts[json.dumps(identity, sort_keys=True)].add(r['block'])
        cell.pop('completeBlocksByActualOS', None)
        cell['completeBlockCohorts'] = [{**json.loads(identity), 'blocks': sorted(blocks)}
                                       for identity, blocks in sorted(cohorts.items())]
        cell['completedPrimaryBlocks'] = max(map(len, cohorts.values()), default=0)
        cell['observedRawFiles'] = [r['file'] for r in observed]
        cell['status'] = 'replication-satisfied' if cell['completedPrimaryBlocks'] >= cell['requiredCompleteIndependentBlocks'] else 'incomplete'
        if 'SE' in cell['deviceCatalogName'] and ledger['unavailableExecutions']:
            cell['status'] = 'unavailable-infrastructure-no-inference'
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

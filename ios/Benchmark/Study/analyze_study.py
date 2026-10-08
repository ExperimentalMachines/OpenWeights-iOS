#!/usr/bin/env python3
"""Aggregate independent report blocks, retaining artifact and OS differences."""
import argparse
import hashlib
import json
import statistics
import re
from collections import defaultdict
from pathlib import Path

METRICS = ['firstCallbackMs', 'streamTokensPerSecond', 'elapsedMs', 'peakFootprintBytes',
           'totalPromptTokens', 'cachedTokens', 'cancellationLatencyMs']


def summary(values):
    values = sorted(values)
    def percentile(fraction):
        position = (len(values) - 1) * fraction
        low = int(position)
        high = min(low + 1, len(values) - 1)
        return values[low] + (values[high] - values[low]) * (position - low)
    return {'n': len(values), 'median': statistics.median(values), 'p25': percentile(.25),
            'p75': percentile(.75), 'minimum': values[0], 'maximum': values[-1]}


def facts(turn, output):
    if turn.get('expectedText') is not None:
        expected = re.escape(turn['expectedText'].lower())
        pattern = r'(?:dietary rule\s*(?::|is)\s*)?' + expected + r'(?: diet)?[.!]?'
        return re.fullmatch(pattern, output.strip().lower().strip('"')) is not None
    fields = turn.get('expectedFields')
    if fields is None:
        return None
    stripped = output.strip()
    lines = stripped.splitlines()
    if len(lines) >= 3 and lines[0] in ['```', '```json'] and lines[-1] == '```':
        stripped = '\n'.join(lines[1:-1])
    try:
        answer = json.loads(stripped)
        return isinstance(answer, dict) and all(str(answer.get(k, '')).lower() == str(v).lower() for k, v in fields.items())
    except (ValueError, TypeError):
        return False


def formatting(turn, output):
    stripped = output.strip()
    if turn.get('expectedText') is not None:
        if turn['expectedText'].isdigit():
            return re.fullmatch(r'[0-9]+', stripped) is not None
        return re.fullmatch(r'[^\W\d_]+', stripped) is not None
    fields = turn.get('expectedFields')
    if fields is None:
        return None
    try:
        answer = json.loads(stripped)
        return isinstance(answer, dict) and all(key in answer for key in fields)
    except (ValueError, TypeError):
        return False


from build_cohort import source_cohort


def analyze(paths, minimum):
    cells = defaultdict(lambda: defaultdict(list))
    sources, failures, seen = [], [], set()
    primary_blocks, retry_rows, failed_reports = set(), [], []
    loads = defaultdict(list)
    for path in paths:
        raw = path.read_bytes()
        report = json.loads(raw)
        run_id = report['runID']
        if run_id in seen:
            raise ValueError(f'Duplicate runID would inflate replication: {run_id}')
        seen.add(run_id)
        cohort = source_cohort(path, raw)
        sources.append({'file': path.name, 'sha256': hashlib.sha256(raw).hexdigest(), 'runID': run_id, **cohort})
        if not report['completed'] and not report['rows']:
            failed_reports.append({'runID': run_id, 'device': report['device'], 'operatingSystem': report['operatingSystem'], 'reason': 'Report ended before an adapter row was recorded'})
        for row in report['rows']:
            identity = {'device': report['device'], 'operatingSystem': report['operatingSystem'],
                        'engine': row['engine'], 'artifactID': row['artifact']['id'],
                        'artifactHashes': {f['file']: f['sha256'] for f in row['artifact']['files']},
                        'runtimeVersions': report['runtimeVersions'], 'contextTokens': report['contextTokens'],
                        'maxOutputTokens': report['maxOutputTokens'],
                        'buildCohortSHA256': cohort['buildCohortSHA256'],
                        'protocolID': (report.get('study') or {}).get('protocolID')}
            study = report.get('study')
            if study:
                block_key = json.dumps([identity, study['scenario'], study['block']], sort_keys=True)
                if study.get('attempt', 0) > 0:
                    retry_rows.append({**identity, 'runID': run_id, 'block': study['block'], 'attempt': study['attempt'], 'phase': row.get('phase'), 'error': row.get('error'), 'retainedSamples': len(row['samples'])})
                    continue
                if block_key in primary_blocks:
                    raise ValueError('Duplicate primary study block. Mark retries with --attempt=1 or greater.')
                primary_blocks.add(block_key)
            load_key = json.dumps({**identity, 'scenario': (study or {}).get('scenario', (report.get('multiTurnWorkload') or {}).get('id'))}, sort_keys=True)
            loads[load_key].append({'runID': run_id, 'loadMs': row.get('loadMs'),
                'loadPeakFootprintBytes': row.get('loadPeakFootprintBytes'),
                'adapterComplete': row.get('phase') == 'complete', 'reportCompleted': report['completed']})
            if row.get('error') or row.get('phase') != 'complete' or not report['completed']:
                failures.append({**identity, 'runID': run_id, 'phase': row.get('phase'), 'error': row.get('error'),
                                 'reportCompleted': report['completed'], 'retainedSamples': len(row['samples'])})
            for sample in row['samples']:
                group = {**identity, 'scenario': (report.get('study') or {}).get('scenario', sample.get('conversationID')), 'workload': sample['workload'],
                         'turn': sample.get('turn'), 'cachePolicy': sample.get('cachePolicy')}
                workload = report.get('multiTurnWorkload') or {}
                if sample['workload'] == 'multi-turn' and sample.get('turn') == workload.get('interruptionBeforeTurn'):
                    group['cachePolicy'] = 'reset-after-interruption'
                entry = {**sample, 'lowPowerMode': report['lowPowerMode'], 'reportCompleted': report['completed'],
                         'adapterComplete': row.get('phase') == 'complete'}
                turns = (report.get('multiTurnWorkload') or {}).get('turns', [])
                if sample.get('turn') and sample['turn'] <= len(turns):
                    entry['factualRecall'] = facts(turns[sample['turn'] - 1], sample['output'])
                    entry['formattingPassed'] = formatting(turns[sample['turn'] - 1], sample['output'])
                cells[json.dumps(group, sort_keys=True)][run_id].append(entry)
    output = []
    for key, runs in sorted(cells.items()):
        cell = json.loads(key)
        complete_count = sum(all(s['reportCompleted'] and s['adapterComplete'] for s in samples) for samples in runs.values())
        cell.update(independentReports=len(runs), belowPlannedReplication=complete_count < minimum,
                    fullyCompletedReports=complete_count,
                    samples=sum(map(len, runs.values())), metrics={}, nominalOnlyMetrics={}, completeReportMetrics={})
        for metric in METRICS:
            all_values, nominal_values, complete_values = [], [], []
            for samples in runs.values():
                values = [s[metric] for s in samples if s.get(metric) is not None]
                nominal = [s[metric] for s in samples if s.get(metric) is not None and s['thermalStart'] == 0 and s['thermalEnd'] == 0 and not s['lowPowerMode']]
                if values:
                    all_values.append(statistics.median(values))
                if nominal:
                    nominal_values.append(statistics.median(nominal))
                complete = [s[metric] for s in samples if s.get(metric) is not None and s['reportCompleted'] and s['adapterComplete']]
                if complete:
                    complete_values.append(statistics.median(complete))
            if all_values:
                cell['metrics'][metric] = summary(all_values)
            if nominal_values:
                cell['nominalOnlyMetrics'][metric] = summary(nominal_values)
            if complete_values:
                cell['completeReportMetrics'][metric] = summary(complete_values)
        samples = [s for block in runs.values() for s in block]
        cell['shortOutputSamples'] = sum(s['generatedTokens'] < 8 for s in samples)
        for name, sample_key in [('factualRecall', 'factualRecall'), ('strictFormatting', 'formattingPassed'),
                                 ('strictProbeSuccess', 'memoryProbePassed')]:
            graded = [s[sample_key] for s in samples if s.get(sample_key) is not None]
            cell[name] = {'passed': sum(graded), 'graded': len(graded)}
            complete_graded = [s[sample_key] for s in samples if s.get(sample_key) is not None and s['reportCompleted'] and s['adapterComplete']]
            cell['completeReport' + name[0].upper() + name[1:]] = {'passed': sum(complete_graded), 'graded': len(complete_graded)}
        output.append(cell)
    load_cells = []
    for key, values in sorted(loads.items()):
        cell = json.loads(key)
        cell.update(independentReports=len(values), fullyCompletedReports=sum(v['adapterComplete'] and v['reportCompleted'] for v in values), metrics={})
        for name in ['loadMs', 'loadPeakFootprintBytes']:
            # A failed initializer leaves these fields at zero. That is not a
            # measured instantaneous load or zero process footprint.
            numbers = [v[name] for v in values if v[name] is not None and v[name] > 0]
            if numbers: cell['metrics'][name] = summary(numbers)
        cell['unmeasuredLoadMetrics'] = {name: sum(v[name] is None or v[name] <= 0 for v in values)
                                       for name in ['loadMs', 'loadPeakFootprintBytes']}
        load_cells.append(cell)
    return {'schemaVersion': 5, 'gradingVersion': 3, 'status': 'analysis-only-study-completion-unverified',
            'minimumIndependentBlocksPerCell': minimum, 'sources': sources, 'cells': output,
            'loadCells': load_cells, 'failedRows': failures, 'failedReports': failed_reports, 'retryRows': retry_rows, 'notes': [
                'Expected-text facts accept exact values, a dietary-rule prefix, a diet suffix and final punctuation. The original combined exact-output check remains strictProbeSuccess.',
                'Grading version 3 separates structural formatting from correct facts. The old combined answer check remains strictProbeSuccess.',
                'Format-only grading checks an unwrapped JSON object with required keys, a single alphabetic diet word, or an integer budget. It does not require the correct value.',
                'Within-report repetitions are collapsed to a median before between-report statistics.',
                'Artifact hashes, runtime versions, exact retained source/build fingerprints, protocol ID and OS remain separate cells.',
                'Explicit retries are retained separately and do not inflate primary replication. Duplicate primary block IDs are rejected.',
                'Reset-after-interruption policy is derived from the recorded workload interruption turn and the runner reset contract.',
                'Failures and partial reports remain evidence. Missing planned cells require the execution ledger.',
                'Fully completed counts and complete-report sensitivity metrics exclude partial blocks without discarding their recorded measurements.',
                'Analysis schema 4 excludes zero or missing unmeasured load defaults from load distributions and reports their counts. Actual positive load measurements survive later generation failures. Factual and format grading remain version 3.',
                'Analysis schema 5 requires a raw-hash-bound source proof for every input and prevents different source maps, executable maps or compile toolchains from pooling replication or distributions.',
                'Analysis alone does not prove the planned device/scenario matrix or product parity.']}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('reports', type=Path, nargs='+')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--minimum-blocks', type=int, default=5)
    args = parser.parse_args()
    if args.minimum_blocks < 1:
        parser.error('--minimum-blocks must be positive')
    result = analyze(args.reports, args.minimum_blocks)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(f"{len(result['sources'])} independent reports, {len(result['cells'])} cells, {len(result['failedRows'])} failed rows")


if __name__ == '__main__':
    main()

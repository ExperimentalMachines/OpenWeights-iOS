#!/usr/bin/env python3
"""Plot one replicated artifact across explicitly selected device/OS cohorts."""
import argparse
import hashlib
import json
import math
import os
import platform
from pathlib import Path

ENGINES = ['llama.cpp CPU', 'ExecuTorch XNNPACK', 'llama.cpp Metal',
           'MLX Metal', 'llama.cpp partial Metal', 'ExecuTorch Core ML', 'ExecuTorch MLX']
SCENARIOS = ['S1-stable-facts', 'S2-workshop-corrections', 'S3-interruption-recovery']
DEVICE_NAMES = {'iPhone17,3': 'iPhone 16', 'iPhone17,1': 'iPhone 16 Pro',
                'iPhone14,6': 'iPhone SE (3rd gen)'}
METRICS = [('firstCallbackMs', 1000, 'First text (seconds)'),
           ('streamTokensPerSecond', 1, 'Decode (tokens/second)'),
           ('peakFootprintBytes', 1048576, 'Peak sampled process\nfootprint (MiB)')]


def select_cells(analysis, engine, scenario, cohorts):
    """Reject missing replication and ambiguous cohorts before writing any assets."""
    if analysis['minimumIndependentBlocksPerCell'] != 5:
        raise ValueError('Expected the five-block study protocol.')
    if not cohorts or len(set(cohorts)) != len(cohorts):
        raise ValueError('Select distinct device/OS cohorts explicitly.')
    selected = []
    for device, version in cohorts:
        matches = [c for c in analysis['cells'] if c['device'] == device
                   and c['operatingSystem'] == version and c['engine'] == engine
                   and c['scenario'] == scenario and c['turn'] == 6
                   and c['workload'] == 'multi-turn']
        if len(matches) != 1:
            raise ValueError(f'{device} / {version}: missing or ambiguous artifact/cache cohort.')
        cell = matches[0]
        count = cell['fullyCompletedReports']
        if count < 5:
            raise ValueError(f'{device} / {version}: only {count}/5 complete primary blocks.')
        if cell['contextTokens'] != 2048 or cell['maxOutputTokens'] != 64:
            raise ValueError('Context/output controls differ from the study protocol.')
        for metric, _, _ in METRICS:
            value = cell['completeReportMetrics'].get(metric, {})
            numbers = [value.get(k) for k in ['p25', 'median', 'p75']]
            if (value.get('n') != count or any(not isinstance(v, (int, float))
                    or not math.isfinite(v) or v <= 0 for v in numbers)
                    or numbers != sorted(numbers)):
                raise ValueError(f'{device}: invalid complete-report metric {metric}.')
        selected.append(cell)
    keys = ['artifactHashes', 'artifactID', 'runtimeVersions', 'cachePolicy',
            'contextTokens', 'maxOutputTokens']
    if analysis.get('schemaVersion', 0) >= 5:
        keys += ['buildCohortSHA256', 'protocolID']
    for key in keys:
        if any(c[key] != selected[0][key] for c in selected[1:]):
            raise ValueError(f'Selected cohorts differ in {key}. Do not pool or silently compare them.')
    return selected


def render(analysis_path, output_dir, engine, scenario, cohorts):
    raw = analysis_path.read_bytes()
    analysis = json.loads(raw)
    cells = select_cells(analysis, engine, scenario, cohorts)
    os.environ.setdefault('MPLCONFIGDIR', str(Path(__file__).resolve().parents[1]
                                            / '.build/matplotlib-cache'))
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt

    selection = {'engine': engine, 'scenario': scenario, 'cohorts': cohorts}
    selection_hash = hashlib.sha256(json.dumps(selection, sort_keys=True).encode()).hexdigest()
    plt.rcParams.update({'font.size': 9, 'font.family': 'DejaVu Sans',
                         'axes.spines.top': False, 'axes.spines.right': False,
                         'svg.fonttype': 'none', 'pdf.fonttype': 42,
                         'svg.hashsalt': hashlib.sha256(raw).hexdigest() + selection_hash})
    figure, axes = plt.subplots(1, 3, figsize=(12, 4.4), sharey=True)
    labels = [f"{DEVICE_NAMES.get(c['device'], c['device'])}\n{c['operatingSystem']}\nn={c['fullyCompletedReports']} complete blocks"
              for c in cells]
    for axis, (metric, divisor, label) in zip(axes, METRICS):
        values = [c['completeReportMetrics'][metric] for c in cells]
        medians = [v['median'] / divisor for v in values]
        errors = [[(v['median'] - v['p25']) / divisor for v in values],
                  [(v['p75'] - v['median']) / divisor for v in values]]
        axis.errorbar(medians, range(len(cells)), xerr=errors, fmt='o', color='#052B42',
                      ecolor='#3B8D7A', markersize=6, capsize=4, linewidth=1.5)
        axis.set_xlabel(label)
        axis.set_xlim(left=0, right=max(v['p75'] / divisor for v in values) * 1.10)
        axis.grid(axis='x', color='#dddddd', linewidth=.6)
        axis.set_axisbelow(True)
    axes[0].set_yticks(range(len(cells)), labels)
    axes[0].invert_yaxis()
    figure.suptitle(f'Qwen3-0.6B: {engine}, final turn of {scenario.split("-")[0]}', fontsize=12)
    figure.text(.5, .88, 'Complete primary blocks only | points: median, bars: IQR', ha='center')
    figure.text(.02, .035, 'Same pinned artifact, runtime versions and cache policy. OS and lab conditions differ.\n'
                'Includes non-nominal thermal samples. See report sensitivity analysis and full study coverage.\n'
                'These observations do not isolate hardware effects, general quality, energy or Neural Engine placement.', fontsize=8)
    figure.subplots_adjust(left=.25, right=.98, top=.80, bottom=.24, wspace=.35)
    output_dir.mkdir(parents=True, exist_ok=True)
    slug = engine.lower().replace(' ', '-').replace('.', '')
    base = output_dir / f'ios-study-{scenario.split("-")[0]}-{slug}-device-cohorts-{selection_hash[:12]}'
    assets = []
    for extension in ['png', 'svg', 'pdf']:
        path = base.with_suffix('.' + extension)
        creator = 'OpenWeights Study/plot_device_cohorts.py'
        metadata = ({'Creator': creator, 'CreationDate': None, 'ModDate': None} if extension == 'pdf'
                    else {'Creator': creator, 'Date': None} if extension == 'svg' else None)
        figure.savefig(path, dpi=180, metadata=metadata)
        assets.append({'file': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    provenance = {'status': 'replicated-selected-cohorts-only-not-full-study-completion-proof',
                  'selection': selection, 'plotSourceSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  'analysisFile': analysis_path.name, 'analysisSHA256': hashlib.sha256(raw).hexdigest(),
                  'analysisSources': analysis['sources'], 'metricCohort': 'complete-independent-primary-reports-only',
                  'figureIsQualityRanking': False, 'hardwareEffectsIsolated': False,
                  'python': platform.python_version(), 'matplotlib': matplotlib.__version__,
                  'metrics': [m[0] for m in METRICS], 'cells': cells, 'assets': assets}
    base.with_suffix('.json').write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n')
    plt.close(figure)
    return base


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('analysis', type=Path)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--engine', choices=ENGINES, required=True)
    parser.add_argument('--scenario', choices=SCENARIOS, required=True)
    parser.add_argument('--cohort', action='append', required=True, metavar='DEVICE=EXACT_OS')
    args = parser.parse_args()
    cohorts = []
    for value in args.cohort:
        device, separator, version = value.partition('=')
        if not separator or not device or not version:
            parser.error('Each cohort requires DEVICE=EXACT_OS.')
        cohorts.append((device, version))
    try:
        print(render(args.analysis, args.output_dir, args.engine, args.scenario, cohorts))
    except ValueError as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()

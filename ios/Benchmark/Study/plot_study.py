#!/usr/bin/env python3
"""Export replicated local artifact observations with between-block IQR."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path

os.environ.setdefault('MPLCONFIGDIR', str(Path(__file__).resolve().parents[1] / '.build/matplotlib-cache'))

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

ORDER = ['llama.cpp CPU', 'ExecuTorch XNNPACK', 'llama.cpp Metal', 'MLX Metal', 'llama.cpp partial Metal']
LABELS = ['O1 CPU', 'O2 XNNPACK', 'O3 full Metal', 'O4 standalone MLX', 'O5 partial Metal']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('analysis', type=Path)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--scenarios', nargs='+', choices=['S1-stable-facts', 'S2-workshop-corrections', 'S3-interruption-recovery'], default=['S1-stable-facts'])
    parser.add_argument('--include-executorch-mlx', action='store_true')
    parser.add_argument('--include-coreml', action='store_true')
    args = parser.parse_args()
    raw = args.analysis.read_bytes()
    analysis = json.loads(raw)
    order = ORDER + (['ExecuTorch Core ML'] if args.include_coreml else []) + (['ExecuTorch MLX'] if args.include_executorch_mlx else [])
    labels = LABELS + (['O6 Core ML FP16'] if args.include_coreml else []) + (['O7 ExecuTorch MLX'] if args.include_executorch_mlx else [])
    for scenario in args.scenarios:
        render(args, analysis, raw, scenario, order, labels)


def render(args, analysis, raw, scenario, order, labels):
    cells = [c for c in analysis['cells'] if c['device'] == 'iPhone17,3' and c.get('scenario') == scenario
             and c.get('turn') == 6 and c['workload'] == 'multi-turn' and c['engine'] in order]
    assert len(cells) == len(order) and {c['engine'] for c in cells} == set(order), 'Missing or mixed artifact cohorts.'
    assert all(c['fullyCompletedReports'] >= 5 for c in cells), 'Figure requires complete planned local replication.'
    cells.sort(key=lambda c: order.index(c['engine']))
    assert len({c['operatingSystem'] for c in cells}) == 1
    assert all(c['contextTokens'] == 2048 and c['maxOutputTokens'] == 64 for c in cells)
    os_version = cells[0]['operatingSystem'].replace('Version ', 'iOS ')
    plt.rcParams.update({'font.size': 10, 'font.family': 'DejaVu Sans', 'axes.spines.top': False,
                         'axes.spines.right': False, 'svg.fonttype': 'none', 'pdf.fonttype': 42,
                         'svg.hashsalt': hashlib.sha256(raw).hexdigest()})
    figure, axes = plt.subplots(1, 2, figsize=(10, 5.2 if len(order) == 7 else 4.9 if len(order) == 6 else 4.6), sharey=True)
    for axis, metric, divisor, label in [(axes[0], 'firstCallbackMs', 1000, 'First text (seconds)'),
                                         (axes[1], 'peakFootprintBytes', 1048576, 'Peak sampled process footprint (MiB)')]:
        values = [c['completeReportMetrics'][metric] for c in cells]
        assert all(v['n'] >= 5 and 0 < v['p25'] <= v['median'] <= v['p75'] for v in values), 'Missing/invalid complete-report metrics.'
        medians = [v['median'] / divisor for v in values]
        errors = [[(v['median'] - v['p25']) / divisor for v in values],
                  [(v['p75'] - v['median']) / divisor for v in values]]
        axis.errorbar(medians, list(range(len(order))), xerr=errors, fmt='o', color='#052B42', ecolor='#3B8D7A',
                      markersize=6, capsize=4, linewidth=1.5)
        if args.include_coreml and metric == 'firstCallbackMs':
            # Static-step Core ML latency spans two orders of magnitude here.
            axis.set_xscale('log')
            axis.set_xlabel('First text (seconds, log scale)')
        else:
            axis.set_xlabel(label)
            axis.set_xlim(left=0)
        axis.grid(axis='x', color='#dddddd', linewidth=.6)
        axis.set_axisbelow(True)
    axes[0].set_yticks(list(range(len(order))), labels)
    axes[0].invert_yaxis()
    short = scenario.split('-')[0]
    figure.suptitle(f'Qwen3-0.6B artifacts: iPhone 16, final turn of {short}', fontsize=13)
    counts = {c['fullyCompletedReports'] for c in cells}
    replication = f'{next(iter(counts))} complete independent blocks/configuration' if len(counts) == 1 else 'complete blocks: ' + ', '.join(str(c['fullyCompletedReports']) for c in cells)
    figure.text(.5, .89, f'{os_version} | {replication} | points: median, bars: IQR',
                ha='center', fontsize=9)
    figure.text(.02, .035, 'Greedy, 64 output tokens, 2k context. Quantization, templates and cache policy differ.\n'
                'Artifact observations, not runtime-only effects. Process footprint is not energy. Full device/Core ML matrix incomplete.', fontsize=9)
    figure.subplots_adjust(left=.18, right=.98, top=.82, bottom=.21, wspace=.25)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    suffix = '-seven-configurations' if args.include_coreml and args.include_executorch_mlx else '-with-coreml' if args.include_coreml else '-six-configurations' if args.include_executorch_mlx else ''
    base = args.output_dir / f'ios-study-{short}-local-final-turn{suffix}'
    assets = []
    for extension in ['png', 'svg', 'pdf']:
        path = base.with_suffix('.' + extension)
        metadata = {'Creator': 'OpenWeights Study/plot_study.py', 'CreationDate': None, 'ModDate': None} if extension == 'pdf' else {'Creator': 'OpenWeights Study/plot_study.py', 'Date': None} if extension == 'svg' else None
        figure.savefig(path, dpi=180, metadata=metadata)
        assets.append({'file': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    provenance = {'status': 'replicated-local-subset-multi-device-CoreML-study-incomplete',
                  'scenario': scenario, 'includedEngines': order,
                  'plotSourceSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  'metricCohort': 'complete-independent-reports-only',
                  'figureIsQualityRanking': False,
                  'analysisFile': args.analysis.name, 'analysisSHA256': hashlib.sha256(raw).hexdigest(),
                  'python': platform.python_version(), 'matplotlib': matplotlib.__version__,
                  'metrics': ['firstCallbackMs', 'peakFootprintBytes'], 'cells': cells, 'assets': assets}
    base.with_suffix('.json').write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n')
    plt.close(figure)


if __name__ == '__main__':
    main()

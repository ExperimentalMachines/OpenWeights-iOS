#!/usr/bin/env python3
"""Render retained evidence while keeping missing matrix cells explicit."""
import argparse
import json
from pathlib import Path

IDS = {'llama.cpp CPU': 'O1', 'ExecuTorch XNNPACK': 'O2', 'llama.cpp Metal': 'O3',
       'MLX Metal': 'O4', 'llama.cpp partial Metal': 'O5', 'ExecuTorch Core ML': 'O6', 'ExecuTorch MLX': 'O7'}
SCENARIOS = [('S1-stable-facts', 'Stable facts'), ('S2-workshop-corrections', 'Updated facts'),
             ('S3-interruption-recovery', 'Interruption and recovery')]


def score(cell, name):
    result = cell['completeReport' + name]
    return f"{result['passed']}/{result['graded']}"


def render(analysis):
    if analysis['gradingVersion'] != 3:
        raise ValueError('This report requires independent format grading version 3.')
    strict_builds = analysis.get('schemaVersion', 0) >= 5
    replicated = {}
    replicated_planned_cells = set()
    for cell in analysis['cells']:
        if cell['device'] != 'iPhone17,3' or cell.get('turn') != 6 or cell['workload'] != 'multi-turn' or cell['fullyCompletedReports'] < 5:
            continue
        keys = ['engine', 'operatingSystem', 'artifactHashes', 'runtimeVersions']
        if strict_builds: keys += ['buildCohortSHA256', 'protocolID']
        identity = json.dumps({k: cell[k] for k in keys}, sort_keys=True)
        replicated.setdefault(identity, set()).add(cell['scenario'])
    complete_local = sum(len(scenarios) == 3 for scenarios in replicated.values())
    mlx_replicated = any(json.loads(key)['engine'] == 'ExecuTorch MLX' and len(scenarios) == 3 for key, scenarios in replicated.items())
    coreml_s1_replicated = any(json.loads(key)['engine'] == 'ExecuTorch Core ML' and 'S1-stable-facts' in scenarios for key, scenarios in replicated.items())
    if strict_builds:
        replicated_planned_cells = {(c['device'], c['engine'], c['scenario']) for c in analysis['cells']
            if c.get('turn') == 6 and c['workload'] == 'multi-turn' and c['fullyCompletedReports'] >= 5}
    status = f'Status: publication draft, matrix incomplete. {complete_local} local artifact configuration{'s' if complete_local != 1 else ''} {'have' if complete_local != 1 else 'has'} five complete independent blocks in each of three scenarios. Core ML and cloud replication remain incomplete. Initial GGUF routing is recorded in ADR-0004. Final cross-format recommendations remain open.'
    if strict_builds:
        status += f' Strict source/build matching satisfies {len(replicated_planned_cells)} of 63 planned cells. The historical 19-cell count pooled builds and is superseded.'
    lines = ['# OpenWeights iOS repeated artifact study', '',
             status, '',
             '## Methods', '',
             'The protocol compares pinned Qwen3-0.6B artifacts in three six-turn synthetic conversations. S1 retains original facts, S2 replaces stale facts, and S3 cancels an auxiliary generation before turn 4, resets the adapter and reconstructs the recorded conversation. Each device/OS/artifact/scenario cell requires five independent report blocks. Greedy decoding, thinking off, 64 output tokens and a 2,048-token ceiling are fixed. Fast runtime order rotates by block. Core ML runs separately.', '',
             'Primary requests use each adapter\'s documented cache policy. Prefix-enabled adapters also replay the identical recorded messages after resetting the conversation. Adapter-load timing is separate from request timing. Filesystem caches are not controlled. Process footprint is sampled, not total system memory or energy.', '',
             'Different quantization, exports, templates and cache policies make comparisons between formats artifact comparisons. CPU, full Metal and partial Metal share the same GGUF and native prompt/decoder implementation, permitting a controlled offload comparison. The delegate target also links different dependencies, so whole-process footprint is not isolated backend memory. OS and lab conditions differ between devices. Synthetic recall does not establish general conversational quality.', '',
             '## Final-turn observations', '',
             'First text is the measured first callback. Values are medians and interquartile ranges between independent complete reports. Partial reports remain in the analysis, including complete adapter rows in globally incomplete reports. The tables use complete-report sensitivity metrics. A row with one completed block is descriptive and does not satisfy the replication target.', '',
             'Exact expected values and requested output structure are graded independently. The factual score requires every requested value, including its spelling. It does not measure semantic equivalence or give partial credit. A correct fenced JSON object passes facts and fails plain-JSON format. A structurally valid object with a wrong value can pass format and fail facts. The original combined harness check remains available as strictProbeSuccess.', '']
    for scenario, title in SCENARIOS:
        lines += [f'### {title}', '',
                  '| Device and actual OS | Config | Build cohort | Complete blocks | First text ms, median [p25, p75] | Decode tokens/s | Peak process MiB | Facts | Format |',
                  '|---|---|---|---:|---:|---:|---:|---:|---:|']
        selected = [c for c in analysis['cells'] if c.get('scenario') == scenario and c.get('turn') == 6 and c['workload'] == 'multi-turn']
        for c in sorted(selected, key=lambda c: (c['device'], c['operatingSystem'], IDS.get(c['engine'], c['engine']))):
            metrics = c['completeReportMetrics']
            if 'firstCallbackMs' not in metrics:
                continue
            latency = metrics['firstCallbackMs']
            lines.append(f"| {c['device']}, {c['operatingSystem']} | {IDS[c['engine']]} {c['engine']} | {c.get('buildCohortSHA256', 'historical-unseparated')[:12]} | {c['fullyCompletedReports']} | "
                         f"{latency['median']:.1f} [{latency['p25']:.1f}, {latency['p75']:.1f}] | "
                         f"{metrics['streamTokensPerSecond']['median']:.2f} | {metrics['peakFootprintBytes']['median'] / 1048576:.1f} | "
                         f"{score(c, 'FactualRecall')} | {score(c, 'StrictFormatting')} |")
        lines.append('')
    lines += ['## Interpretation', '',
              'F1. Full Metal and standalone MLX have shorter local S1/S2 final-turn first-text latency than the tested CPU, partial-Metal and XNNPACK configurations. Standalone MLX uses substantially more sampled process memory. Its S1/S2 final answers retain the tested facts but wrap the JSON in Markdown fences in all five blocks.', '',
              'F2. In S3, all five baseline configurations complete interruption/recovery. The final all-values factual score fails in all five completed blocks for CPU, full Metal, partial Metal and standalone MLX, while XNNPACK passes all five. Every artifact retains Maple, Lisbon and budget 350 in 5/5 blocks. The failed value is the spelling of pescatarian: CPU returns pescant, full/partial Metal return pescantarian, and standalone MLX returns pescarian. These literal-value mismatches do not establish that the intended dietary preference was forgotten. This is an output-level artifact difference. Different exports and prompt templates prevent attributing it to a runtime alone. It does not demonstrate cache corruption or general model quality.', '',
              'F3. Initial product GGUF routing uses full Metal when available, with an explicit CPU choice, based on the controlled local offload comparison. Core ML remains benchmark-only. The product has an experimental ExecuTorch MLX path whose scoped verification and retained failures are tracked in ios/Product/parity.md. Broader recommendations require the unfinished Core ML and device cells.', '',
              '## Failures and incomplete cells', '',
              'S2 block 1 was killed by iOS for CPU usage while non-frontmost. Its partial checkpoint and separately marked successful retry are retained. The retry does not increase primary replication. The foreground guard later cancelled S2 blocks 2 and 5 and S3 block 3. Additional independent blocks supplied five complete primary conversations for each local baseline scenario. Partial and empty reports remain in the ledger.', '',
              'Two historical SE 3 study submissions, on catalog iOS 18.4 and the approved 26.3 replacement, each ended after three infrastructure attempts without an inference report. Later compatibility checks passed nine full-Metal smoke requests and then 45 current-build requests across five baseline configurations on actual iOS 18.4 (22E240). Those checks are separate from the repeated study. All SE study cells remain incomplete, and historical failures do not establish current device unavailability.', '',
              'The first cloud Pro S1 block completed on actual iOS 18.3.1. The next reported iOS 18.3.2 and stopped after 30 requests because the phone did not cool to nominal within three minutes following MLX. MLX ended at fair temperature. These OS cohorts remain separate, and the partial block does not supply a full repetition. Cloud charging state and ambient temperature are unknown.', '',
              'Core ML cells and cloud replication remain pending. Core ML\'s historical static-step FP16 result is slow and belongs to the pilot evidence, not these repeated-study tables. Missing and unavailable cells are recorded in Study/execution-ledger-2026-10-03.json.', '',
              '## Reproduction and provenance', '',
              'Run Study/analyze_study.py with the raw paths below, --minimum-blocks 5 and an output JSON path. Run Study/report_study.py ANALYSIS_JSON --appendix Study/report-appendix-2026-10-04.md --output REPORT.md to regenerate this report including the retained acquisition records. Run Study/update_ledger.py ANALYSIS_JSON Study/execution-ledger-2026-10-03.json to refresh execution counts. These commands run from ios/Benchmark. The analyzer separates actual device/OS, artifact hashes, runtime versions, scenario, turn and cache policy. Complete-report and nominal-only sensitivity metrics are included in the JSON.', '',
              'Protocol: Study/protocol-v1.json, grading version 3. Study/grading-v3.md records the post-baseline correction separating formatting from facts. The version-2 analyzer, pre-addendum protocol and earlier analyses are preserved. Factual expectations and raw outputs are unchanged.', '',
              'Source/build fingerprints and exact archived sources accompany local and cloud reports. The foreground guard was added after the first S2 CPU kill, so later harness source cohorts differ without an engine-algorithm change. No energy or Neural Engine placement was measured. Publication artifacts are prepared locally and have not been published.', '',
              'Raw input files and SHA-256:', '']
    if strict_builds:
        lines[lines.index('## Interpretation') + 2] = ('F1. Replicated local S1 measurements show shorter final-turn first-text latency for full Metal and standalone MLX than CPU, partial Metal and XNNPACK. S2 baseline comparisons now split into one earlier and four foreground-guard blocks. They remain descriptive within each build cohort and do not satisfy five matching repetitions.')
        original = next(i for i, text in enumerate(lines) if text.startswith('F2. In S3'))
        lines[original] = ('F2. The historical S3 baseline results combined one earlier build with four foreground-guard blocks. All five conversations remain retained, but neither build supplies five matching blocks. Exact spelling failures remain observations in their separate cohort rows. They do not establish cache corruption, a lost dietary preference or general model quality.')
        original = next(i for i, text in enumerate(lines) if text.startswith('S2 block 1 was killed'))
        lines[original] = ('S2 block 1 was killed by iOS while non-frontmost. Partial checkpoints and explicit retries remain retained. The foreground guard cancelled later S2 and S3 attempts. Four complete foreground-guard primary blocks exist per baseline scenario, plus one earlier complete block. Different compiled source/executable fingerprints cannot supply a fifth matching repetition. The historical 19-cell tally is corrected to nine source/build-matched cells.')
        original = next(i for i, text in enumerate(lines) if text.startswith('Source/build fingerprints and exact archived'))
        lines[original] = ('Schema 5 binds every raw report to its retained source proof and separates exact source maps, executable maps and compile toolchains, alongside artifact, device/OS, protocol, context/output controls and cache policy. Missing or mismatched source proofs are refused. The foreground-guard source change is a distinct build cohort. No energy or Neural Engine placement was measured. Dated appendix counts are historical snapshots and do not override this corrected coverage.')
        original = next(i for i, text in enumerate(lines) if text.startswith('Run Study/analyze_study.py'))
        lines[original] += ' Keep every paired source proof beside its raw report. Schema 5 groups load and turn distributions by buildCohortSHA256 as well as artifact and OS.'
    index = lines.index('Raw input files and SHA-256:')
    if mlx_replicated:
        figures = ['The figures show all six replicated local configurations in each scenario. Each point is the median of five complete independent blocks, with between-block interquartile ranges. They compare first-text latency and sampled whole-process footprint, not quality or energy. Facts and formatting remain separate in the tables above.', '']
        for scenario, title in SCENARIOS:
            short = scenario.split('-')[0]
            figures += [f'![{title}: local final-turn latency and sampled process memory](assets/ios-study/ios-study-{short}-local-final-turn-six-configurations.png)', '']
        figures += ['From ios/Benchmark, regenerate with .build/plot-tools/bin/python Study/plot_study.py Results/study-analysis-in-progress-v3-2026-10-03.json --output-dir ../../docs/research/assets/ios-study --scenarios S1-stable-facts S2-workshop-corrections S3-interruption-recovery --include-executorch-mlx. Plot dependencies are pinned in Study/plot-requirements.txt. PNG, SVG, PDF and input/output hash metadata are retained. The outputs reproduce byte-for-byte with the retained plotting environment.', '',
                    'The [historical five-configuration S1 figure](assets/ios-study/ios-study-S1-local-final-turn.png) and its [frozen provenance](assets/ios-study/ios-study-S1-local-final-turn.json) remain retained. It predates ExecuTorch MLX replication.', '']
    else:
        figures = ['The S1 latency and memory figure shows the five baseline configurations using their frozen five-block analysis. It excludes the later ExecuTorch MLX repetitions. Those numeric measurements are unchanged by the format-grading correction:', '',
                   '![Local S1 final-turn latency and sampled process memory](assets/ios-study/ios-study-S1-local-final-turn.png)', '',
                   'Regenerate with .build/plot-tools/bin/python Study/plot_study.py Results/iphone16-S1-five-block-analysis-v2-2026-10-02.json --output-dir ../../docs/research/assets/ios-study. Plot dependencies are pinned in Study/plot-requirements.txt. PNG, SVG, PDF and input/output hash metadata are retained.', '']
    if strict_builds:
        figures = ['Historical figures and their frozen analyses remain retained. The S2/S3 six-configuration figures pooled different source/build cohorts and do not prove five matching blocks. They are not used as current replication figures.', '',
                   'The local S1 seven-configuration figure remains a five-matching-build-block result within each configuration. Current source/build-separated table rows above supply the authoritative counts.', '']
    lines[index:index] = figures
    if mlx_replicated:
        index = lines.index('## Failures and incomplete cells')
        lines[index:index] = ['F4. The corrected 2k ExecuTorch MLX export now completes five independent local blocks in S1, S2 and S3. Every final turn passes exact facts and plain-JSON formatting in 5/5 blocks. Median final-turn first text is 1.23 to 1.35 seconds, decode throughput is 68.10 to 69.76 tokens/s, and sampled whole-process footprint is 2,063 to 2,208 MiB. This artifact rebuilds each turn. These results do not establish a universal runtime winner or energy efficiency.', '']
        index = lines.index('Two historical SE 3 study submissions, on catalog iOS 18.4 and the approved 26.3 replacement, each ended after three infrastructure attempts without an inference report. Later compatibility checks passed nine full-Metal smoke requests and then 45 current-build requests across five baseline configurations on actual iOS 18.4 (22E240). Those checks are separate from the repeated study. All SE study cells remain incomplete, and historical failures do not establish current device unavailability.')
        lines[index:index] = ['ExecuTorch MLX S1 block 0 first failed before launch while locked. Attempt 1 later cancelled on app inactivity after five recorded turns. Attempt 2 completed, remains a retry, and does not inflate primary replication. Independent S1 blocks 1 through 5 supply the five-block target. S2 and S3 each use independent blocks 0 through 4. The launch receipt, partial report, retry and all source snapshots are retained.', '']
    if coreml_s1_replicated:
        core = next(c for c in analysis['cells'] if c['device'] == 'iPhone17,3' and c['engine'] == 'ExecuTorch Core ML'
                    and c['scenario'] == 'S1-stable-facts' and c['turn'] == 6 and c['workload'] == 'multi-turn'
                    and c['fullyCompletedReports'] >= 5)
        latency = core['completeReportMetrics']['firstCallbackMs']
        index = lines.index('## Failures and incomplete cells')
        lines[index:index] = [f"F5. The static-step FP16 Core ML CPU/GPU artifact now has {core['fullyCompletedReports']} complete matching local S1 blocks. Final-turn first text is {latency['median'] / 1000:.2f} seconds, with an IQR of {latency['p25'] / 1000:.2f} to {latency['p75'] / 1000:.2f} seconds. All final JSON answers retain the requested facts and structure. Each block's earlier one-word dietary probe returns diet instead of vegan. This is replicated local S1 evidence, not completed S2/S3 or multi-device replication. The artifact rebuilds the prompt each turn. No Neural Engine, energy or runtime-only conclusion follows.", '']
        old = "Core ML cells and cloud replication remain pending. Core ML's historical static-step FP16 result is slow and belongs to the pilot evidence, not these repeated-study tables. Missing and unavailable cells are recorded in Study/execution-ledger-2026-10-03.json."
        cloud_coreml = [c for c in analysis['cells'] if c['device'] == 'iPhone17,1'
                        and c['engine'] == 'ExecuTorch Core ML' and c['scenario'] == 'S1-stable-facts'
                        and c['turn'] == 6 and c['workload'] == 'multi-turn']
        cloud_counts = ', '.join(f"{c['fullyCompletedReports']}/5 complete blocks on {c['operatingSystem']}"
                                 for c in cloud_coreml)
        lines[lines.index(old)] = ('Local Core ML S1 meets the five-block target. Core ML S2/S3 and cloud replication remain incomplete. '
                                  + ('Cloud Core ML Pro S1 has ' + cloud_counts + '. ' if cloud_counts else '')
                                  + 'Actual OS cohorts remain separate. Missing and unavailable cells are recorded in Study/execution-ledger-2026-10-03.json.')
        if cloud_coreml:
            index = lines.index('## Reproduction and provenance')
            thermal_counts = ', '.join(
                f"{c['nominalOnlyMetrics']['firstCallbackMs']['n']}/{c['fullyCompletedReports']} final-turn samples on {c['operatingSystem']}"
                for c in cloud_coreml)
            lines[index:index] = ['Cloud Core ML final-turn thermal sensitivity: only ' + thermal_counts
                                 + ' have nominal thermal state at both request boundaries. Non-nominal measurements remain in the main results, with nominal-only metrics retained separately in the analysis JSON. These samples do not establish a temperature-controlled hardware comparison.', '']
        index = lines.index('Raw input files and SHA-256:')
        lines[index:index] = ['The additional S1 figure includes all seven configurations with five matching complete local blocks each. Its latency axis uses a log scale because the static-step Core ML artifact is much slower. The historical six-configuration figures above remain unchanged.', '',
                            '![Stable facts: seven replicated local configurations](assets/ios-study-coreml-five-20261007/ios-study-S1-local-final-turn-seven-configurations.png)', '',
                            'Regenerate from ios/Benchmark with .build/plot-tools/bin/python Study/plot_study.py Results/study-analysis-coreml-local-five-and-cloud-one-v3-2026-10-07.json --output-dir ../../docs/research/assets/ios-study-coreml-five-20261007 --scenarios S1-stable-facts --include-coreml --include-executorch-mlx. PNG, SVG, PDF and provenance hashes are retained.', '']
    if strict_builds and coreml_s1_replicated:
        lines = [line.replace('assets/ios-study-coreml-five-20261007/', 'assets/ios-study-source-build-20261007/')
                 .replace('Results/study-analysis-coreml-local-five-and-cloud-one-v3-2026-10-07.json', 'Results/study-analysis-source-build-separated-schema5-grading3-2026-10-07.json')
                 .replace('--output-dir ../../docs/research/assets/ios-study-coreml-five-20261007', '--output-dir ../../docs/research/assets/ios-study-source-build-20261007')
                 for line in lines]
    for source in analysis['sources']:
        lines.append(f"- `{source['file']}`: `{source['sha256']}`" + (f", build `{source['buildCohortSHA256']}`, source proof `{source['sourceProofFile']}` (`{source['sourceProofSHA256']}`)" if strict_builds else ''))
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('analysis', type=Path)
    parser.add_argument('--appendix', type=Path, help='Append retained acquisition and validation records.')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = render(json.loads(args.analysis.read_text()))
    if args.appendix:
        report += '\n' + args.appendix.read_text()
    args.output.write_text(report)


if __name__ == '__main__':
    main()

# OpenWeights iOS benchmark page

Public static report for the reduced CPU/Metal conversation benchmark, measured
2026-10-07 and published 2026-10-08. GitHub Pages deploys only this directory.
The full raw execution archives remain private.

- `data/observations.json`: allowlisted turn measurements, actual generated
  replies, thermal states, strict-format outcomes and original report hashes.
- `data/*-summary.csv` and `data/*-turns.csv`: exact tables for three separate
  cohorts, never pooled.
- `reproduce.py`: standard-library-only aggregate reproduction with the frozen
  factual scorer. Run `python3 site/reproduce.py` from the repository root.
- `data/measured-sources.zip`: exact compiled native source inputs for the
  five-model study. Binary hashes and pinned native revision are in build JSON.
- `assets/reproduction.zip`: observations, cohort metadata, workload, tables
  and the reproduction script. Extract and run `python3 reproduce.py`.
- `verify.py`: verifies aggregates, file hashes, local links and the public
  allowlist. Used by the Pages workflow before deployment.

The HTML contains complete tables without JavaScript. JavaScript adds native
metric/model selectors, comparative bars, a per-turn plot and an optional theme
switch. Fonts are local, with license notices. No analytics, third-party scripts
or network-dependent data loading are used.

To regenerate from retained private evidence: run
`python3 tools/export-benchmark-site.py`, then
`python3 tools/build-benchmark-page.py`. Figures use
`python3 tools/plot-publication.py` with Matplotlib 3.10.8. After changing the public
bundle, run `python3 tools/package-publication.py` and `python3 site/verify.py`.

Reproduction validates the published aggregates, not the native execution of a
new benchmark. The four metrics do not measure energy, total GPU residency,
general intelligence or Android/iOS performance under matched conditions.

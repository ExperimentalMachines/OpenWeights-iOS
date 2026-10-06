# Grading version 3: independent factual and format scores

Recorded: 2026-10-02, after the local baseline scenario repetitions and before delegate-study expansion. Raw outputs and hardware measurements are unchanged.

The version-2 field named `strictFormatting` used the harness's `memoryProbePassed` value. That combined factual correctness with the requested output form. An unwrapped, structurally valid JSON answer with a misspelled diet was counted as a format failure too. This did not separate the two requested metrics.

Version 3 keeps the factual grader unchanged and scores output structure independently. JSON probes require a plain JSON object containing the requested keys. Their values are evaluated by the factual grader. Diet probes require one alphabetic word with no prefix, quotes or punctuation. Budget probes require one integer with no extra text. A wrong single word can therefore pass format and fail facts. A correct fenced JSON object can pass facts and fail format.

The original combined check is retained as `strictProbeSuccess`. The analysis schema and grading version both advance to 3 because the meaning of `strictFormatting` changes. `analyze_study_v2.py`, the earlier analyses and the frozen pre-addendum protocol preserve the old behavior. The source outputs can be rescored with either version. This addendum is a correction to metric labeling and separation, not a change to factual expectations or decoding.

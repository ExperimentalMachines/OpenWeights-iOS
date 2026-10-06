#!/usr/bin/env python3
"""Compare actual sampled native IDs with the independent Rust full decoder."""
import json
import sys
from pathlib import Path

from tokenizers import Tokenizer, __version__

tokenizer = Tokenizer.from_file(sys.argv[1])
native = json.loads(Path(sys.argv[2]).read_text())
comparisons = []
for index, record in enumerate(native['observations']):
    if 'content' not in record:
        continue
    decoded = tokenizer.decode(record['sampledTokenIDs'], skip_special_tokens=True)
    comparisons.append({'observation': index, 'decoded': decoded,
                        'matchesNativeReply': decoded == record['content'],
                        'streamMatchesNativeReply': record['streamMatchesReply']})
proof = {'implementation': 'Hugging Face Rust tokenizers', 'version': __version__,
         'skipSpecialTokens': True, 'comparisons': comparisons,
         'passed': bool(comparisons) and all(c['matchesNativeReply'] and c['streamMatchesNativeReply'] for c in comparisons),
         'limitations': ['Decoding fidelity for the sampled IDs does not establish requested-spelling accuracy or general model quality.']}
Path(sys.argv[3]).write_text(json.dumps(proof, indent=2, ensure_ascii=False) + '\n')
raise SystemExit(0 if proof['passed'] else 1)

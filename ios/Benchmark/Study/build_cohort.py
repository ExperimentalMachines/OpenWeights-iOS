"""Bind analysis cohorts to the retained raw report and exact source/build receipt."""
import hashlib
import json
from pathlib import Path


def source_cohort(path, raw):
    path = Path(path)
    proof_path = path.with_name(path.stem + '-source.json')
    if not proof_path.exists():
        # Three initial reports use dated raw names and undated source proofs.
        legacy = path.with_name(path.stem.removesuffix('-2026-10-02') + '-source.json')
        if legacy == proof_path or not legacy.exists():
            raise ValueError('Missing retained source proof: ' + path.name)
        proof_path = legacy
    proof_bytes = proof_path.read_bytes()
    proof = json.loads(proof_bytes)
    binding = proof.get('rawReport', {})
    filename = proof.get('rawResultsFile', binding.get('file'))
    expected = proof.get('rawResultsSHA256', binding.get('sha256'))
    if filename != path.name or expected != hashlib.sha256(raw).hexdigest():
        raise ValueError('Source proof does not bind the exact raw report: ' + path.name)
    receipt = proof.get('buildReceipt', {})
    for name in ['sources', 'executables']:
        values = receipt.get(name)
        if not isinstance(values, dict) or not values or not all(
                isinstance(k, str) and isinstance(v, str) and len(v) == 64
                and all(c in '0123456789abcdef' for c in v) for k, v in values.items()):
            raise ValueError('Missing or invalid build fingerprints: ' + path.name)
    if not all(isinstance(receipt.get(k), str) and receipt[k] for k in ['xcode', 'sdk']):
        raise ValueError('Missing retained toolchain identity: ' + path.name)
    # Exact source maps, executable maps and compile toolchain define a cohort.
    # Artifact, protocol, cache and device controls remain separate row identities.
    identity = {k: receipt[k] for k in ['sources', 'executables', 'xcode', 'sdk']}
    fingerprint = hashlib.sha256(json.dumps(identity, sort_keys=True,
                                            separators=(',', ':')).encode()).hexdigest()
    return {'buildCohortSHA256': fingerprint, 'sourceProofFile': proof_path.name,
            'sourceProofSHA256': hashlib.sha256(proof_bytes).hexdigest(),
            'xcode': receipt['xcode'], 'sdk': receipt['sdk']}

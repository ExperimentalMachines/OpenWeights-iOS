"""Prepare the pinned Qwen checkpoint or describe locally exported artifacts."""
import argparse
import hashlib
import importlib.metadata
import json
import shutil
from pathlib import Path

SOURCE_REPO = "Qwen/Qwen3-0.6B"
SOURCE_REVISION = "c1899de289a04d12100db370d81485cdf75e47ca"


def digest(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def checkpoint():
    import torch
    from executorch.examples.models.qwen3.convert_weights import (
        load_checkpoint, qwen_3_tune_to_meta,
    )
    torch.save(qwen_3_tune_to_meta(load_checkpoint(".build/source-model")), ".build/qwen3-checkpoint.pt")


def manifest():
    artifacts = []
    for name, quantization in [
        ("coreml", "Core ML uncompressed FP16 weights; FP16 KV cache"),
        ("executorch-mlx", "TorchAO int4 linear weights, group 32, HQQ scale-only; FP16 embedding and KV cache"),
    ]:
        root = Path("Models") / name
        if not (root / "model.pte").is_file():
            raise FileNotFoundError(f"Export missing: {root / 'model.pte'}")
        shutil.copyfile(".build/source-model/tokenizer.json", root / "tokenizer.json")
        config = Path("Export") / ("coreml.yaml" if name == "coreml" else "mlx.yaml")
        provenance = {
            "sourceRepo": SOURCE_REPO,
            "sourceRevision": SOURCE_REVISION,
            "sourceWeightsSHA256": digest(Path(".build/source-model/model.safetensors")),
            "executorchSourceRevision": "f7140a46ff38e919c557d45b102d3ff26097c8c9",
            "versions": {p: importlib.metadata.version(p) for p in ["executorch", "torch", "torchao", "coremltools", "pytorch-tokenizers"]},
            "exportConfiguration": json.loads(config.read_text()),
            "paramsSHA256": digest(Path("Export/qwen3-params.json")),
            "configurationSHA256": digest(config),
            "artifactSHA256": digest(root / "model.pte"),
            "coremlBoundaryWorkaroundSHA256": digest(Path("Export/coreml_export.py")) if name == "coreml" else None,
            "delivery": "bundled local export, not published to Hugging Face",
        }
        (root / "export-provenance.json").write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
        files = [{"file": file.name, "bytes": file.stat().st_size, "sha256": digest(file)}
                 for file in sorted(root.iterdir()) if file.is_file()]
        artifacts.append({"id": name, "repo": SOURCE_REPO, "revision": SOURCE_REVISION,
                          "quantization": quantization, "files": files})
    Path("Resources/model-manifest-delegates.json").write_text(
        json.dumps({"upstream": SOURCE_REPO, "artifacts": artifacts}, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", choices=["checkpoint", "manifest"])
    args = parser.parse_args()
    checkpoint() if args.stage == "checkpoint" else manifest()

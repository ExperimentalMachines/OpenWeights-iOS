"""Compare Core ML exports with FP32 source inference on the benchmark prompts."""
import argparse
import gc
import hashlib
import importlib.metadata
import json
import platform
from datetime import datetime, timezone
from pathlib import Path

import torch
from executorch.runtime import Runtime
from transformers import AutoModelForCausalLM, AutoTokenizer

EOS = {151643, 151645}
QUESTIONS = {
    "short": "Explain why leaves are green in three short sentences.",
    "long": "The garden has trees, flowers, and a pond. " * 40
    + "Summarize this description in two short sentences.",
}


def digest(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def render_prompt(question):
    return (
        "<|im_start|>system\nYou are a helpful assistant. "
        "Follow the user's instructions precisely.<|im_end|>\n"
        f"<|im_start|>user\n{question}<|im_end|>\n"
        "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    )


@torch.inference_mode()
def reference(source, tokenizer, max_tokens):
    model = AutoModelForCausalLM.from_pretrained(
        source, local_files_only=True, dtype=torch.float32
    ).eval()
    cases = {}
    for name, question in QUESTIONS.items():
        prompt = render_prompt(question)
        tokens = tokenizer.encode(prompt, add_special_tokens=False)
        current = torch.tensor([tokens])
        cache, generated, logits = None, [], []
        for _ in range(max_tokens):
            output = model(current, past_key_values=cache, use_cache=True)
            cache = output.past_key_values
            prediction = output.logits[0, -1].float().clone()
            token = int(prediction.argmax())
            logits.append(prediction)
            generated.append(token)
            if token in EOS:
                break
            current = torch.tensor([[token]])
        cases[name] = {
            "prompt": prompt, "promptTokens": tokens, "tokens": generated,
            "output": tokenizer.decode(generated, skip_special_tokens=True),
            "logits": logits,
        }
        print(f"Reference {name}: {cases[name]['output']}", flush=True)
    del model, cache, output
    gc.collect()
    return cases


@torch.inference_mode()
def candidate(path, cases, tokenizer, max_tokens):
    program = Runtime.get().load_program(path)
    forward = program.load_method("forward")

    def step(token, pos):
        value = forward.execute([
            torch.tensor([[token]], dtype=torch.long),
            torch.tensor([pos], dtype=torch.long),
        ])[0].reshape(-1).float().clone()
        if not torch.isfinite(value).all():
            raise ValueError(f"Nonfinite logits in {path} at position {pos}")
        return value

    results = {}
    for name, case in cases.items():
        prompt = case["promptTokens"]
        metrics = []
        # Position zero starts a fresh causal prefix. Every visible cache slot is
        # overwritten before use, and the mask excludes the old suffix.
        for pos, token in enumerate(prompt + case["tokens"][:-1]):
            actual = step(token, pos)
            if pos < len(prompt) - 1:
                continue
            index = pos - len(prompt) + 1
            expected = case["logits"][index]
            metrics.append({
                "step": index,
                "referenceTop1": int(expected.argmax()),
                "exportTop1": int(actual.argmax()),
                "rmse": float((actual - expected).square().mean().sqrt()),
                "cosine": float(torch.nn.functional.cosine_similarity(actual, expected, dim=0)),
            })
        for pos, token in enumerate(prompt):
            actual = step(token, pos)
        generated = []
        for index in range(max_tokens):
            token = int(actual.argmax())
            generated.append(token)
            if token in EOS or index == max_tokens - 1:
                break
            actual = step(token, len(prompt) + index)
        results[name] = {
            "teacherForcedSteps": len(metrics),
            "top1Agreement": sum(m["referenceTop1"] == m["exportTop1"] for m in metrics) / len(metrics),
            "meanRMSE": sum(m["rmse"] for m in metrics) / len(metrics),
            "meanCosine": sum(m["cosine"] for m in metrics) / len(metrics),
            "greedyTokens": generated,
            "greedyOutput": tokenizer.decode(generated, skip_special_tokens=True),
            "metrics": metrics,
        }
        print(f"{path.name} {name}: {results[name]['greedyOutput']}", flush=True)
    return {"file": path.name, "bytes": path.stat().st_size,
            "sha256": digest(path), "workloads": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("models", nargs="+", type=Path)
    parser.add_argument("--source", type=Path, default=Path(".build/source-model"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--max-tokens", type=int, default=64)
    args = parser.parse_args()
    if not 1 <= args.max_tokens <= 64:
        parser.error("Use between 1 and 64 output tokens to match the pilot.")
    torch.set_num_threads(6)
    tokenizer = AutoTokenizer.from_pretrained(args.source, local_files_only=True)
    cases = reference(args.source, tokenizer, args.max_tokens)
    report = {
        "purpose": "export-numerical-validation, not a performance benchmark or quality score",
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "host": {"system": platform.system(), "os": platform.mac_ver()[0], "architecture": platform.machine()},
        "reference": {"runtime": "Transformers CPU FP32", "sourceWeightsSHA256": digest(args.source / "model.safetensors"),
                      "sourceConfigSHA256": digest(args.source / "config.json")},
        "validatorSHA256": digest(__file__),
        "versions": {p: importlib.metadata.version(p) for p in ["executorch", "torch", "transformers", "coremltools"]},
        "maxOutputTokens": args.max_tokens,
        "notes": ["Teacher forcing compares each export after the same reference prefix.",
                  "Greedy outputs are generated separately and require content review.",
                  "Two prompts do not establish general answer quality or iPhone numerical behavior."],
        "workloads": {name: {k: v for k, v in case.items() if k != "logits"} for name, case in cases.items()},
        "candidates": [],
    }
    for path in args.models:
        report["candidates"].append(candidate(path, cases, tokenizer, args.max_tokens))
        gc.collect()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Saved {args.output}", flush=True)


if __name__ == "__main__":
    main()

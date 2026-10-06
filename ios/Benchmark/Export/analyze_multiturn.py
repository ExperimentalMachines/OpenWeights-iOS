"""Summarize recorded multi-turn runs without changing their raw reports."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path

from tokenizers import Tokenizer


def digest(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def prompt(messages):
    return "".join(f"<|im_start|>{m['role']}\n{m['content']}<|im_end|>\n" for m in messages) + "<|im_start|>assistant\n<think>\n\n</think>\n\n"


def retained_facts(turn, output):
    if "expectedText" in turn:
        return output.strip().strip(".*_`").lower() == turn["expectedText"].lower()
    if "expectedFields" not in turn:
        return None
    text = output.strip()
    if text.startswith("```") and text.endswith("```"):
        lines = text.splitlines()
        if lines[0].lower() in ("```json", "```") and lines[-1] == "```":
            text = "\n".join(lines[1:-1])
    try:
        actual = json.loads(text)
    except (ValueError, TypeError):
        return False
    return isinstance(actual, dict) and all(str(actual.get(k, "")).lower() == v.lower() for k, v in turn["expectedFields"].items())


def analyze(path, tokenizer, allow_partial=False):
    report = json.loads(path.read_text())
    assert report["purpose"] == "multi-turn-scaling-pilot"
    if not report["completed"] and not allow_partial:
        raise ValueError(f"{path}: incomplete report requires --allow-partial")
    rows = []
    for row in report["rows"]:
        samples = []
        for sample in row["samples"]:
            explicit = prompt(sample["messages"])
            explicit_hash = hashlib.sha256(explicit.encode()).hexdigest()
            if sample.get("renderedPromptSHA256"):
                assert sample["renderedPromptSHA256"] == explicit_hash
            tokens = len(tokenizer.encode(explicit, add_special_tokens=False).ids)
            assert tokens + report["maxOutputTokens"] <= report["contextTokens"]
            if sample.get("totalPromptTokens") is not None:
                assert sample["totalPromptTokens"] + report["maxOutputTokens"] <= report["contextTokens"]
            turn = report["multiTurnWorkload"]["turns"][sample["turn"] - 1]
            samples.append({
                "turn": sample["turn"], "cachePolicy": sample["cachePolicy"],
                "explicitPromptTokens": tokens, "nativeTotalPromptTokens": sample.get("totalPromptTokens"),
                "cachedTokens": sample.get("cachedTokens"),
                "firstCallbackMs": sample["firstCallbackMs"],
                "streamTokensPerSecond": sample.get("streamTokensPerSecond"),
                "generatedTokens": sample["generatedTokens"], "stopReason": sample["stopReason"],
                "peakProcessFootprintMiB": sample["peakFootprintBytes"] / 2**20,
                "thermalStart": sample["thermalStart"], "thermalEnd": sample["thermalEnd"],
                "strictProbePassed": sample.get("memoryProbePassed"),
                "retainedFactsPassed": retained_facts(turn, sample["output"]),
            })
        primary = [s for s in samples if s["cachePolicy"] != "reset-each-turn"]
        probes = [s for s in primary if s["retainedFactsPassed"] is not None]
        next_turn = None
        if primary and len(primary) < len(report["multiTurnWorkload"]["turns"]) and row["phase"] != "complete":
            last = next(s for s in reversed(row["samples"]) if s["cachePolicy"] != "reset-each-turn")
            turn = report["multiTurnWorkload"]["turns"][last["turn"]]
            content = turn.get("padding", "") * turn.get("paddingRepeats", 0) + turn["user"]
            messages = last["messages"] + [{"role": "assistant", "content": last["output"]}, {"role": "user", "content": content}]
            text = prompt(messages)
            tokens = len(tokenizer.encode(text, add_special_tokens=False).ids)
            next_turn = {"turn": last["turn"] + 1, "explicitPromptTokens": tokens,
                         "renderedPromptSHA256": hashlib.sha256(text.encode()).hexdigest(),
                         "fitsContextWithOutputReserve": tokens + report["maxOutputTokens"] <= report["contextTokens"],
                         "note": "Reconstructed next prompt from the checkpoint and fixture. No completed response or timing is recorded."}
        rows.append({"engine": row["engine"], "artifact": row["artifact"]["id"],
                     "artifactManifestSHA256": hashlib.sha256(json.dumps(row["artifact"], sort_keys=True).encode()).hexdigest(),
                     "phase": row["phase"], "error": row.get("error"), "samples": samples,
                     "uncompletedNextTurn": next_turn,
                     "completedTurnCount": len(primary),
                     "expectedTurnCount": len(report["multiTurnWorkload"]["turns"]),
                     "expectedProbeCount": sum("expectedText" in t or "expectedFields" in t for t in report["multiTurnWorkload"]["turns"]),
                     "primaryStrictProbePasses": sum(s["strictProbePassed"] is True for s in probes),
                     "primaryRetainedFactsPasses": sum(s["retainedFactsPassed"] is True for s in probes),
                     "probeCount": len(probes)})
    return {"file": path.name, "sha256": digest(path), "runID": report["runID"],
            "reportCompleted": report["completed"], "rows": rows}


def splicing_diagnostic(report_path, tokenizer):
    report = json.loads(report_path.read_text())
    row = next((r for r in report["rows"] if r["engine"] == "llama.cpp CPU"), None)
    if not row:
        return None
    last = next(s for s in row["samples"] if s["turn"] == 6 and s["workload"] == "multi-turn")
    earlier = next(s for s in row["samples"] if s["turn"] == 5 and s["workload"] == "multi-turn")
    reply, text = earlier["output"], prompt(last["messages"])
    at = text.find(reply)
    if at < 0:
        return None
    plain = tokenizer.encode(text, add_special_tokens=False).ids
    spliced = sum((tokenizer.encode(piece, add_special_tokens=False).ids for piece in [text[:at], reply, text[at + len(reply):]]), [])
    differences = [i for i, (a, b) in enumerate(zip(plain, spliced)) if a != b]
    return {"reply": reply, "firstMatchIsInSeedUserMessage": reply in last["messages"][1]["content"],
            "plainTokens": len(plain), "oneMatchSplicedTokens": len(spliced),
            "firstDivergenceToken": differences[0] if differences else None,
            "observedDeviceCachedTokens": last["cachedTokens"],
            "note": "Host tokenization simulation of the shared engine's first-text-match reply splicing. This is not an isolated native regression test."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--tokenizer", type=Path, default=Path(".build/source-model/tokenizer.json"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--allow-partial", action="store_true", help="Include checkpointed observations with explicit completion and coverage fields.")
    args = parser.parse_args()
    tokenizer_hash = digest(args.tokenizer)
    if tokenizer_hash != "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4":
        parser.error("Tokenizer differs from the pinned Qwen pilot tokenizer.")
    tokenizer = Tokenizer.from_file(str(args.tokenizer))
    result = {
        "purpose": "multi-turn pilot analysis", "analyzerSHA256": digest(__file__),
        "tokenizerSHA256": tokenizer_hash, "tokenizersVersion": importlib.metadata.version("tokenizers"),
        "notes": ["Explicit prompt counts describe the recorded ChatML template. Native GGUF tokenization can differ.",
                  "The raw memoryProbePassed field checks both content and strict output format. Retained facts are scored separately here, allowing one JSON code fence or surrounding punctuation on the one-word answer.",
                  "Each engine has one conversation. Per-turn values are observations, not repeated medians.",
                  "Reset replay uses identical messages. Native reply-token splicing can change token sequences after earlier generation.",
                  "Incomplete checkpoints report only completed observations. Missing turns and probes are unobserved, not successes.",
                  "reportCompleted means the runner finished iterating configurations. A failed row remains a failed execution even when the report is complete."],
        "runs": [analyze(path, tokenizer, args.allow_partial) for path in args.reports],
        "llamaSplicingDiagnostic": next((d for path in args.reports if (d := splicing_diagnostic(path, tokenizer))), None),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Saved {args.output}")


if __name__ == "__main__":
    main()

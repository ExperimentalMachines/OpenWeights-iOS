#!/usr/bin/env python3
"""Prepare, run and summarize the bounded publication profile. Plan is device-free."""
import argparse
import copy
import csv
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import shutil
import statistics
import subprocess
import time
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
RUNTIMES = ["llama.cpp CPU", "llama.cpp Metal"]
PROTOCOL = "openweights-ios-publication-v1"


def save(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_manifest(manifest):
    artifacts = manifest["artifacts"]
    if not artifacts or len({a["id"] for a in artifacts}) != len(artifacts):
        raise ValueError("Select distinct pinned GGUF artifacts.")
    for artifact in artifacts:
        if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", artifact["id"])
                or len(artifact["files"]) != 1 or not re.fullmatch(r"[0-9a-f]{40}", artifact["revision"])):
            raise ValueError("Each model requires one GGUF and a pinned Hub commit.")
        file = artifact["files"][0]
        url = urlparse(file["url"])
        expected = f"/{artifact['repo']}/resolve/{artifact['revision']}/{file['file']}"
        if (Path(file["file"]).name != file["file"] or not file["file"].endswith(".gguf")
                or not re.fullmatch(r"[0-9a-f]{64}", file["sha256"]) or file["bytes"] <= 0
                or url.scheme != "https" or url.hostname != "huggingface.co"
                or url.path != expected or url.query or url.fragment):
            raise ValueError("Model filename, size, SHA-256 or pinned Hub URL is invalid.")
    return artifacts


def targets(plan):
    if "TestConfigurations" in plan:
        return [t for c in plan["TestConfigurations"] for t in c["TestTargets"]]
    return [value for key, value in plan.items() if key != "__xctestrun_metadata__"]


def absolute_testroot(value, root):
    if isinstance(value, str):
        return value.replace("__TESTROOT__", str(root))
    if isinstance(value, dict):
        return {k: absolute_testroot(v, root) for k, v in value.items()}
    if isinstance(value, list):
        return [absolute_testroot(v, root) for v in value]
    return value


def prepare(base_path, output, manifest_path, budget=3600):
    if not 60 <= budget <= 3600:
        raise ValueError("Measurement budget must be between 60 and 3600 seconds.")
    artifacts = validate_manifest(json.loads(manifest_path.read_text()))
    base = absolute_testroot(plistlib.loads(base_path.read_bytes()), base_path.parent.resolve())
    receipt = base_path.parent / "openweights-build.json"
    if receipt.exists() and json.loads(receipt.read_text()).get("benchmarkVariant") != "gguf-ios16.6-v1":
        raise ValueError("Build the GGUF-only target first. Baseline/delegate plans do not contain this profile.")
    if len(targets(base)) != 1 or targets(base)[0].get("BlueprintName") != "BenchmarkTests":
        raise ValueError("Use the single-target GGUF-only .xctestrun from build-gguf.sh.")
    workload = next(w for w in json.loads((ROOT / "Resources/study-workloads.json").read_text())
                    if w["id"] == "S1-stable-facts")
    output.mkdir(parents=True, exist_ok=False)
    save(output / "models.json", json.loads(manifest_path.read_text()))
    save(output / "workload.json", workload)
    save(output / "protocol.json", {
        "id": PROTOCOL, "repetitions": 3, "turns": 6, "maxOutputTokens": 64,
        "contextTokens": 2048, "runtimes": RUNTIMES, "measurementBudgetSeconds": budget,
        "resetReplay": False, "interruption": False, "automaticRetries": 0,
        "minimumThroughputOutputTokens": 8, "thermalCooldownLimitSeconds": 180,
        "metrics": ["first-text seconds", "streaming tokens/s", "peak process MiB", "recall probes"],
        "workloadSHA256": digest(output / "workload.json"),
        "modelsSHA256": digest(output / "models.json"),
        "recall": "Diagnostic only. Factual matching and strict formatting are reported separately.",
        "limitations": "One conversation repeated three times. No general quality, energy or Android hardware claim."
    })
    if receipt.exists():
        (output / "build-receipt.json").write_bytes(receipt.read_bytes())
        for name, expected in json.loads(receipt.read_text())["sources"].items():
            source = ROOT.parents[1] / name
            if digest(source) != expected:
                raise ValueError("Compiled source changed before snapshot: " + name)
            destination = output / "sources" / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
    for name in ["benchmark.py", "test_benchmark.py", "archive.py", "test_archive.py"]:
        (output / name).write_bytes(Path(__file__).with_name(name).read_bytes())
    records = []

    def add(artifact, stage, repetition=0, runtime=RUNTIMES[0]):
        number = len(records)
        plan = copy.deepcopy(base)
        target = targets(plan)[0]
        target.update(OnlyTestIdentifiers=["BenchmarkTests/testPublicationAcquire" if stage == "acquire"
                                          else "BenchmarkTests/testPublicationConversation"],
                      ParallelizationEnabled=False, TestTimeoutsEnabled=True,
                      DefaultTestExecutionTimeAllowance=900 if stage == "acquire" else 600,
                      MaximumTestExecutionTimeAllowance=900 if stage == "acquire" else 600)
        environment = target.setdefault("EnvironmentVariables", {})
        # Never inherit a historical study selection or unrecorded retry.
        for key in list(environment):
            if key.startswith(("OW_STUDY_", "OW_PUBLICATION_")):
                del environment[key]
        environment.update(OW_PUBLICATION_ARTIFACT=json.dumps(artifact, separators=(",", ":")),
                           OW_PUBLICATION_WORKLOAD=json.dumps(workload, separators=(",", ":")),
                           OW_PUBLICATION_RUNTIME=runtime, OW_PUBLICATION_REPETITION=str(repetition))
        path = output / f"{number:03d}-{stage}.xctestrun"
        path.write_bytes(plistlib.dumps(plan))
        records.append(dict(stage=stage, model=artifact["id"], runtime=runtime, repetition=repetition,
                            plan=path.name, planSHA256=digest(path), status="pending"))

    for artifact in artifacts:
        add(artifact, "acquire")
    for repetition in range(3):
        models = artifacts[repetition % len(artifacts):] + artifacts[:repetition % len(artifacts)]
        for artifact in models:
            for runtime in RUNTIMES[::1 if repetition % 2 == 0 else -1]:
                add(artifact, "measure", repetition, runtime)
    save(output / "index.json", {"protocol": PROTOCOL, "budgetSeconds": budget,
                                "status": "prepared-not-executed", "records": records})
    print(f"Prepared {len(artifacts)} acquisitions and {len(artifacts) * 6} conversations "
          f"({len(artifacts) * 36} requests). No device was contacted.")


def bounded_command(command, log, timeout):
    with log.open("wb") as stream:
        process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=timeout), False
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            # Give XCTest a short opportunity to attach its checkpoint, then stop the host group.
            for sig in [signal.SIGINT, signal.SIGTERM, signal.SIGKILL]:
                try:
                    os.killpg(process.pid, sig)
                except ProcessLookupError:
                    break
                try:
                    process.wait(timeout=3)
                    break
                except subprocess.TimeoutExpired:
                    pass
            return process.wait(), True


def run(folder, device, stage, phone_ready):
    if not phone_ready:
        raise ValueError("Run only after the phone hold is lifted, with --phone-ready.")
    index = json.loads((folder / "index.json").read_text())
    selected = select_records(index, stage)
    if stage != "acquire" and any(r["status"] != "passed" for r in index["records"] if r["stage"] == "acquire"):
        raise ValueError("Finish model acquisition before starting the measurement budget.")
    for record in index["records"]:
        if digest(folder / record["plan"]) != record["planSHA256"]:
            raise ValueError("Prepared XCTest plan changed.")
    protocol = json.loads((folder / "protocol.json").read_text())
    for name in ["models", "workload"]:
        if digest(folder / f"{name}.json") != protocol[f"{name}SHA256"]:
            raise ValueError(f"Prepared {name} changed.")
    if digest(folder / "benchmark.py") != digest(Path(__file__)):
        raise ValueError("Runner changed after preparation. Prepare a new batch.")
    subprocess.run(["python3", str(ROOT / "Export/build_receipt.py"), "check", "--gguf-only"], check=True)
    live = ROOT / ".build/DerivedData-gguf16/Build/Products/openweights-build.json"
    if not (folder / "build-receipt.json").exists() or live.read_bytes() != (folder / "build-receipt.json").read_bytes():
        raise ValueError("Prepare the plans again from the current signed build.")
    current_toolchain = subprocess.check_output(["xcodebuild", "-version"], text=True).strip()
    if current_toolchain != json.loads(live.read_text())["xcode"]:
        raise ValueError("Select the build's Xcode with DEVELOPER_DIR before running this batch.")
    measured = stage != "acquire"
    spent = index.get("measurementSpentSeconds", 0)
    phase_started = time.monotonic()
    deadline = phase_started + index["budgetSeconds"] - spent if measured else None
    index["status"] = stage + "-running"
    save(folder / "index.json", index)
    for number, record in enumerate(index["records"]):
        if number not in selected:
            continue
        remaining = deadline - time.monotonic() if deadline else 900
        if remaining <= 0:
            index["status"] = "budget-exhausted"
            break
        record.update(status="running", executionPhase=stage)
        record["result"] = f"{number:03d}.xcresult"
        save(folder / "index.json", index)
        started = time.monotonic()
        code, expired = bounded_command([
            "xcodebuild", "test-without-building", "-xctestrun", str(folder / record["plan"]),
            "-destination", f"id={device}", "-destination-timeout", "30",
            "-parallel-testing-enabled", "NO", "-resultBundlePath", str(folder / record["result"])
        ], folder / f"{number:03d}.log", min(remaining, 660 if measured else 900))
        record.update(status="timed-out" if expired else "passed" if code == 0 else "failed",
                      exitCode=code, hostElapsedSeconds=round(time.monotonic() - started, 3))
        if measured:
            index["measurementSpentSeconds"] = round(spent + time.monotonic() - phase_started, 3)
        save(folder / "index.json", index)
        print(f"{stage}: {record['model']} / {record['runtime']} / {record['repetition']}: {record['status']}", flush=True)
        if code != 0 or expired:
            index["status"] = "stopped-after-failure"
            break
    else:
        index["status"] = stage + "-complete"
    if measured:
        index["measurementSpentSeconds"] = round(spent + time.monotonic() - phase_started, 3)
    save(folder / "index.json", index)
    # Export after measurements so result extraction does not compete with inference.
    for number, record in enumerate(index["records"]):
        result = folder / record.get("result", "missing")
        if number in selected and result.exists():
            code, expired = bounded_command(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                "--output-path", str(folder / f"{number:03d}-attachments")], folder / f"{number:03d}-export.log", 30)
            record["attachmentExport"] = "passed" if code == 0 and not expired else "failed"
    save(folder / "index.json", index)
    summarize(folder)
    if stage == "calibrate":
        calibrated = json.loads((folder / "index.json").read_text())
        if calibrated["status"] == "calibrate-complete":
            calibrated["durationEstimate"] = calibration_estimate(calibrated)
            save(folder / "index.json", calibrated)
            print(json.dumps(calibrated["durationEstimate"], indent=2), flush=True)
    terminal = json.loads((folder / "index.json").read_text())["status"]
    return 0 if terminal == stage + "-complete" else 1


def select_records(index, stage):
    """Calibration consumes repetition zero of the final batch; it never adds requests."""
    if index["status"] in ["stopped-after-failure", "budget-exhausted", "measurement-evidence-incomplete",
                            "calibration-evidence-incomplete", "acquire-running", "measure-running", "calibrate-running"]:
        raise ValueError("Batch stopped or has unfinished evidence. Do not retry or overwrite it.")
    if stage == "measure" and index["status"] == "calibrate-complete":
        estimate = index.get("durationEstimate", {})
        if not estimate.get("fitsBudget"):
            raise ValueError("Calibration predicts the batch exceeds its budget. Propose a smaller workload and wait for approval.")
        selected = [n for n, r in enumerate(index["records"]) if r["stage"] == "measure" and r["repetition"] > 0]
    else:
        selected = [n for n, r in enumerate(index["records"]) if r["stage"] == ("measure" if stage == "calibrate" else stage)
                    and (stage != "calibrate" or r["repetition"] == 0)]
    if not selected or any(index["records"][n]["status"] != "pending" for n in selected):
        raise ValueError("This stage already has execution evidence. Never overwrite or rerun it.")
    return selected


def calibration_estimate(index):
    first = [r for r in index["records"] if r["stage"] == "measure" and r["repetition"] == 0]
    if not first or any(r["status"] != "passed" or not r.get("reportPresent") for r in first):
        raise ValueError("Estimate requires completed first-repetition reports for every configuration.")
    elapsed = sum(r["hostElapsedSeconds"] for r in first)
    estimate = max(index.get("measurementSpentSeconds", 0), elapsed) * 3 * 1.5
    return {"firstRepetitionHostSeconds": round(elapsed, 3), "projectedThreeRepetitionsSeconds": round(estimate, 3),
            "headroomMultiplier": 1.5, "fitsBudget": estimate <= index["budgetSeconds"],
            "basis": "Actual first repetition across every model/backend, multiplied by three with 50% headroom. Cooling variability is not guaranteed; the cumulative hard budget still applies."}


def factual_grade(output, turn):
    """Ignore JSON fences/prose around an object, but do not infer facts from malformed JSON."""
    if "expectedText" in turn:
        # Accept the one-word fact or an unambiguous positive diet label, not arbitrary prose.
        normalized = output.strip().strip('"\' .!\n\r').lower()
        label = re.fullmatch(r"(?:the\s+)?(?:dietary rule|diet)(?:\s*:\s*|\s+is\s+)([\w-]+)", normalized)
        if label:
            normalized = label[1]
        if re.fullmatch(r"[\w-]+", normalized):
            return normalized == turn["expectedText"].lower()
        return None
    if "expectedFields" in turn:
        decoder = json.JSONDecoder()
        objects = []
        for match in re.finditer(r"\{", output):
            try:
                value, _ = decoder.raw_decode(output[match.start():])
                if isinstance(value, dict):
                    objects.append(value)
            except ValueError:
                pass
        if len(objects) != 1:
            return None
        return all(str(objects[0].get(k, "")).lower() == str(v).lower() for k, v in turn["expectedFields"].items())
    return None


def median(values):
    return statistics.median(values) if values else None


def backend_matches(runtime, backend):
    dominant = backend.split("|", 1)[0].lower()
    return ("metal" in dominant or re.fullmatch(r"mtl\d+", dominant) is not None) if runtime == "llama.cpp Metal" else dominant == "cpu"


def canonical_workload(workload):
    # Swift Codable omits this optional field when nil; the pinned fixture spells it null.
    return {key: value for key, value in workload.items()
            if key != "interruptionBeforeTurn" or value is not None}


def summarize(folder):
    index = json.loads((folder / "index.json").read_text())
    workload = json.loads((folder / "workload.json").read_text())
    models = {a["id"]: a for a in json.loads((folder / "models.json").read_text())["artifacts"]}
    groups = {(model, runtime): [] for model in models for runtime in RUNTIMES}
    process_ids = set()
    for number, record in enumerate(index["records"]):
        if record["stage"] != "measure":
            continue
        reports = {}
        for path in (folder / f"{number:03d}-attachments").rglob("*.json"):
            value = json.loads(path.read_text())
            if isinstance(value, dict) and value.get("purpose") == "publication-conversation-v1":
                reports[value["runID"]] = value
        if not reports and record.get("rawReportPath"):
            retained = folder / record["rawReportPath"]
            if digest(retained) != record["rawReportSHA256"]:
                raise ValueError("Retained raw report changed after collection.")
            value = json.loads(retained.read_text())
            reports[value["runID"]] = value
        if len(reports) > 1:
            raise ValueError("Ambiguous report attachments for one invocation.")
        report = next(iter(reports.values()), None)
        if report:
            process_id = report.get("processIdentifier")
            if not isinstance(process_id, int) or process_id <= 0 or process_id in process_ids:
                raise ValueError("Fresh benchmark process evidence missing or PID reused. Inspect the raw run.")
            process_ids.add(process_id)
            if (report.get("study", {}).get("protocolID") != PROTOCOL
                    or canonical_workload(report.get("multiTurnWorkload", {})) != canonical_workload(workload)
                    or report.get("study", {}).get("block") != record["repetition"] or len(report["rows"]) != 1
                    or report["rows"][0]["artifact"] != models[record["model"]]
                    or report["rows"][0]["engine"] != record["runtime"]):
                raise ValueError("Report does not match its prepared configuration.")
            retained = folder / "retained-reports"
            retained.mkdir(exist_ok=True)
            data = (json.dumps(report, indent=2, sort_keys=True) + "\n").encode()
            sha = hashlib.sha256(data).hexdigest()
            path = retained / f"{number:03d}-{sha}.json"
            if not path.exists():
                path.write_bytes(data)
            record.update(rawReportPath=str(path.relative_to(folder)), rawReportSHA256=sha)
        record["reportPresent"] = report is not None
        groups[record["model"], record["runtime"]].append((record, report))
    rows = []
    turns = []
    for (model, runtime), runs in groups.items():
        samples, peaks = [], []
        complete = 0
        for record, report in runs:
            if not report:
                continue
            row = report["rows"][0]
            record["observedBackend"] = row.get("backend", "")
            record["backendMatchesSelection"] = backend_matches(runtime, row.get("backend", ""))
            valid = (record["status"] == "passed" and report["completed"] and not report["lowPowerMode"]
                     and record["backendMatchesSelection"]
                     and not row.get("error") and [s.get("turn") for s in row["samples"]] == list(range(1, 7))
                     and all(s["stopReason"] in ["eos", "length"] and s["generatedTokens"] > 0
                             and s.get("firstCallbackMs") is not None for s in row["samples"]))
            if valid:
                complete += 1
                nominal = [s for s in row["samples"] if s["thermalStart"] == 0 and s["thermalEnd"] == 0]
                samples.extend(nominal)
                # Memory headline requires the whole conversation to remain nominal.
                if len(nominal) == 6:
                    peaks.append(max([row["loadPeakFootprintBytes"]] + [s["peakFootprintBytes"] for s in nominal]) / 1048576)
        probes = [s for s in samples if s.get("memoryProbePassed") is not None]
        facts = [factual_grade(s["output"], workload["turns"][s["turn"] - 1]) for s in probes]
        rows.append(dict(model=model, runtime=runtime, completedConversations=complete, plannedConversations=3,
            nominalSamples=len(samples), plannedSamples=18,
            firstTextSeconds=median([s["firstCallbackMs"] / 1000 for s in samples]),
            streamingTokensPerSecond=median([s["streamTokensPerSecond"] for s in samples
                if s["generatedTokens"] >= 8 and s.get("streamTokensPerSecond") is not None]),
            peakProcessMiB=median(peaks), factualProbesCorrect=sum(v is True for v in facts),
            factualProbesScorable=sum(v is not None for v in facts), factualProbesUnscorable=sum(v is None for v in facts),
            strictProbesCorrect=sum(s["memoryProbePassed"] for s in probes), observedProbes=len(probes), plannedProbes=9))
        for turn in range(1, 7):
            selected = [s for s in samples if s["turn"] == turn]
            turns.append(dict(model=model, runtime=runtime, turn=turn, nominalSamples=len(selected),
                firstTextSeconds=median([s["firstCallbackMs"] / 1000 for s in selected]),
                streamingTokensPerSecond=median([s["streamTokensPerSecond"] for s in selected
                    if s["generatedTokens"] >= 8 and s.get("streamTokensPerSecond") is not None])))
    for filename, values in [("summary.csv", rows), ("turns.csv", turns)]:
        with (folder / filename).open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(values[0]))
            writer.writeheader(); writer.writerows(values)
    if index["status"] in ["measure-complete", "measurement-evidence-incomplete"]:
        index["status"] = "measure-complete" if all(row["completedConversations"] == 3 for row in rows) else "measurement-evidence-incomplete"
    if index["status"] in ["calibrate-complete", "calibration-evidence-incomplete"]:
        index["status"] = "calibrate-complete" if all(row["completedConversations"] == 1 for row in rows) else "calibration-evidence-incomplete"
    save(folder / "summary.json", {"protocol": PROTOCOL, "status": index["status"], "rows": rows,
        "freshProcessEvidence": "Distinct reported PIDs across attached measurement invocations. Natural PID recycling is possible.",
        "notes": ["Medians of nominal samples from complete successful conversations only. All failures remain in index.json and raw artifacts.",
                  "Throughput excludes replies below eight tokens. Recall is diagnostic, not general intelligence.",
                  "Malformed/ambiguous JSON is factually unscorable and a strict-format failure. Missing probes are visible in planned denominators.",
                  "Peak memory is sampled process footprint, including loading. No engine-only or energy claim."]})
    save(folder / "index.json", index)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("prepare")
    plan.add_argument("--xctestrun", type=Path, required=True)
    plan.add_argument("--output", type=Path, required=True)
    plan.add_argument("--models", type=Path, default=Path(__file__).with_name("pilot-models.json"))
    plan.add_argument("--budget-seconds", type=int, default=3600)
    execute = sub.add_parser("run")
    execute.add_argument("folder", type=Path)
    execute.add_argument("--device", required=True)
    execute.add_argument("--stage", choices=["acquire", "calibrate", "measure"], required=True)
    execute.add_argument("--phone-ready", action="store_true")
    collect = sub.add_parser("summarize")
    collect.add_argument("folder", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            prepare(args.xctestrun.resolve(), args.output.resolve(), args.models.resolve(), args.budget_seconds)
        elif args.command == "run":
            return run(args.folder.resolve(), args.device, args.stage, args.phone_ready)
        else:
            summarize(args.folder.resolve())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(2, str(error) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

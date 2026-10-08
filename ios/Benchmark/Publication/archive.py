#!/usr/bin/env python3
"""Archive a terminal publication batch through the existing verified private workflow."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import zipfile

import benchmark

ROOT = Path(__file__).resolve().parents[3]
WORKSPACE = ROOT.parent


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def package(folder):
    folder = folder.resolve()
    allowed = Path(__file__).resolve().parent / "outputs"
    if not folder.is_relative_to(allowed) or folder == allowed:
        raise ValueError("Archive only batches beneath Publication/outputs.")
    index = json.loads((folder / "index.json").read_text())
    if index["status"] not in ["measure-complete", "measurement-evidence-incomplete",
                                "stopped-after-failure", "budget-exhausted",
                                "cloud-pilot-complete", "cloud-pilot-incomplete"]:
        raise ValueError("Only terminal batches can be archived.")
    if any(record["status"] == "running" for record in index["records"]):
        raise ValueError("A live/unfinished invocation must be reconciled before archival.")
    archive = folder.with_name(folder.name + "-proof.zip")
    manifest = {}
    files = [p for p in sorted(folder.rglob("*")) if p.is_file()]
    if any(p.is_symlink() for p in folder.rglob("*")):
        raise ValueError("Symlink in evidence tree. Inspect before packing.")
    with zipfile.ZipFile(archive, "x", zipfile.ZIP_DEFLATED) as bundle:
        for path in files:
            name = str(path.relative_to(folder))
            before = path.stat()
            manifest[name] = {"bytes": before.st_size, "sha256": digest(path)}
            bundle.write(path, name)
            after = path.stat()
            if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise ValueError("Evidence changed during packaging. Preserve and inspect the partial archive.")
        bundle.writestr("member-manifest.json", json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    with zipfile.ZipFile(archive) as bundle:
        if bundle.testzip() is not None:
            raise ValueError("Evidence ZIP CRC mismatch.")
        for name, entry in manifest.items():
            value = hashlib.sha256()
            with bundle.open(name) as stream:
                for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
                    value.update(chunk)
            if value.hexdigest() != entry["sha256"]:
                raise ValueError("Packaged evidence differs from its source manifest.")
    plan = folder.with_name(folder.name + "-transfer.json")
    benchmark.save(plan, {"bucket": "zeraphim/openweights-ios-artifacts", "files": [{
        "localRelativePath": str(archive.relative_to(WORKSPACE.resolve())), "bytes": archive.stat().st_size}]})
    benchmark.save(folder / "archive-member-manifest.json", manifest)
    benchmark.save(folder / "archive-preparation.json", {
        "archive": str(archive), "sha256": digest(archive), "transferPlan": str(plan),
        "members": len(manifest), "status": "packed-verified-not-uploaded"})
    return archive, plan, manifest


def evict_verified_large_files(folder, manifest):
    """Called only after the existing private transfer passes its round-trip checks."""
    for name, entry in manifest.items():
        path = folder / name
        if not path.exists() or path.stat().st_size != entry["bytes"] or digest(path) != entry["sha256"]:
            raise ValueError("Evidence changed after upload. Retain all local files.")
    # Save all raw JSON reports separately before removing attachment directories.
    retained = folder / "retained-reports"
    retained.mkdir(exist_ok=True)
    for path in folder.glob("*-attachments/**/*.json"):
        try:
            report = json.loads(path.read_text())
        except (ValueError, UnicodeError):
            continue
        if isinstance(report, dict) and report.get("purpose") == "publication-conversation-v1":
            shutil.copyfile(path, retained / (digest(path) + ".json"))
    for path in folder.iterdir():
        if path.is_dir() and (path.suffix == ".xcresult" or path.name.endswith("-attachments")):
            shutil.rmtree(path)


def transfer(folder, python, evict):
    preparation = json.loads((folder / "archive-preparation.json").read_text())
    archive = Path(preparation["archive"])
    if digest(archive) != preparation["sha256"]:
        raise ValueError("Archive changed after packaging.")
    subprocess.run([python, str(ROOT / "migration/archive_packages.py"), "--plan", preparation["transferPlan"]], check=True)
    receipt = json.loads(archive.with_suffix(".zip.remote.json").read_text())
    if (receipt["sha256"] != preparation["sha256"] or not receipt["downloadedSHA256Matches"]
            or not receipt["downloadedZipCRCMatches"] or receipt["status"] != "archived-local-copy-removed"):
        raise ValueError("Private round-trip evidence is incomplete. Do not evict the run.")
    benchmark.save(folder / "remote-receipt.json", receipt)
    if evict:
        evict_verified_large_files(folder, json.loads((folder / "archive-member-manifest.json").read_text()))
    preparation["status"] = "private-round-trip-verified-large-local-files-removed" if evict else "private-round-trip-verified-local-evidence-retained"
    benchmark.save(folder / "archive-preparation.json", preparation)
    print(preparation["status"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["package", "transfer"])
    parser.add_argument("folder", type=Path)
    parser.add_argument("--hf-python", default="/Users/zeraphim/.hf-cli/venv/bin/python")
    parser.add_argument("--evict-large", action="store_true")
    args = parser.parse_args()
    folder = args.folder.resolve()
    if args.mode == "package":
        archive, _, _ = package(folder)
        print(archive)
    else:
        transfer(folder, args.hf_python, args.evict_large)


if __name__ == "__main__":
    main()

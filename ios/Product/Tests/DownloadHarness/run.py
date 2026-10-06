#!/usr/bin/env python3
"""Exercise the actual download controller with held startup/delegate boundaries."""
import hashlib, json, subprocess, zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
generated = root / '.build/download-harness'; sources = generated / 'Sources/DownloadHarness'
sources.mkdir(parents=True, exist_ok=True)
inputs = [root / ('App/' + name) for name in ['ModelDownloads.swift', 'HubCredentialController.swift', 'HubClient.swift', 'HubGGUFRangeSource.swift']]
inputs += [root / 'DeviceTests/DownloadBootstrapChecks.swift', Path(__file__), root / 'Package.swift', root / 'Package.resolved']
inputs += sorted((root / 'Sources/OpenWeightsCore').glob('*.swift'))
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def hashes(): return {str(p.relative_to(root)): digest(p) for p in inputs}
before = hashes()
for p in inputs:
    if p.parent.name == 'App' or p.name == 'DownloadBootstrapChecks.swift': (sources / p.name).write_bytes(p.read_bytes())
(sources / 'Main.swift').write_text('''import Foundation
@main struct DownloadHarness {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-bootstrap-host-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let observations = try await DownloadBootstrapChecks.run(root: root)
        try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
''')
(generated / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DownloadHarness", platforms: [.macOS(.v14)], dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "DownloadHarness", dependencies: [.product(name: "OpenWeightsCore", package: "Product")])])
''')
swift = subprocess.check_output(['swift', '--version'], stderr=subprocess.STDOUT, text=True).strip()
identity = hashlib.sha256(json.dumps({'sources': before, 'swift': swift}, sort_keys=True).encode()).hexdigest()[:12]
output = root / ('Results/download-bootstrap-host-' + identity + '.json')
assert not output.exists(), 'This exact immutable cohort is already retained.'
log = root / ('.build/download-bootstrap-host-' + identity + '.log')
with log.open('x') as stream:
    result = subprocess.run(['swift', 'run', '--package-path', str(generated), '--scratch-path', str(root / '.build/background-bootstrap-before-build'), '-c', 'release', 'DownloadHarness', str(output)], stdout=stream, stderr=subprocess.STDOUT)
if result.returncode: raise SystemExit('Download startup checks failed. Inspect ' + str(log))
assert before == hashes(), 'Sources changed during validation.'
proof = json.loads(output.read_text()); assert len(proof['passedChecks']) == 9
proof.update(compiledSourceSHA256=before, swift=swift, logSHA256=digest(log), retainedLog=str(log.relative_to(root)), status='controlled-startup-callback-host-passed')
archive = output.with_suffix('.zip')
with zipfile.ZipFile(archive, 'x', zipfile.ZIP_DEFLATED) as z:
    for p in inputs: z.write(p, str(p.relative_to(root)))
    z.write(log, 'retained/host.log')
proof['sourceSnapshot'] = {'file': archive.name, 'sha256': digest(archive)}
output.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
print(output.name, 'nine checks passed')

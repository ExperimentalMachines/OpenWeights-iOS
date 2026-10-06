import Foundation
import CryptoKit
import OpenWeightsCore

private struct CheckFailure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws { if !value { throw CheckFailure(message: message) } }
private actor CompiledMetadataProbe {
    let data: Data
    let delay: UInt64
    private(set) var requests: [LocalModel] = []
    init(_ data: Data, delay: UInt64 = 0) { self.data = data; self.delay = delay }
    func read(_ model: LocalModel) async -> Data {
        requests.append(model)
        if delay > 0 { try? await Task.sleep(nanoseconds:delay) }
        return data
    }
}
private actor PinnedDetailsHub: HubDiscoveryTransport {
    private(set) var calls: [URL] = []
    func get(_ url: URL) async throws -> HubAPIResponse {
        calls.append(url)
        let data = try JSONSerialization.data(withJSONObject: ["id": "org/model", "sha": String(repeating: "a", count: 40),
            "siblings": [["rfilename": "model.gguf", "size": 1000]]])
        return HubAPIResponse(status: 200, data: data)
    }
}
private actor ScriptedHub: HubDiscoveryTransport {
    struct Step {
        var ids: [String] = []
        var cursor: String? = nil
        var fail = false
        var delay: UInt64 = 0
    }
    var steps: [Step]
    var calls: [URL] = []
    init(_ steps: [Step]) { self.steps = steps }
    func get(_ url: URL) async throws -> HubAPIResponse {
        calls.append(url)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        let step = steps.removeFirst()
        // Deliberately ignore transport cancellation to exercise the controller guard.
        if step.delay > 0 { try? await Task.sleep(nanoseconds: step.delay) }
        if step.fail { throw URLError(.timedOut) }
        let data = try JSONSerialization.data(withJSONObject: step.ids.map { ["id": $0] })
        return HubAPIResponse(status: 200, data: data, link: step.cursor.map { "<https://huggingface.co/api/models?cursor=\($0)>; rel=next" })
    }
}
@main private struct DiscoveryChecks {
    @MainActor static func idle(_ controller: DiscoveryController) async throws {
        for _ in 0..<200 {
            if !controller.busy && !controller.loadingMore { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CheckFailure(message: "Controller did not finish within its fixture allowance")
    }
    @MainActor static func main() async throws {
        var passed: [String] = []
        let mode = CommandLine.arguments[2]
        var observations: [[String: Any]] = []
        if mode == "live" {
            // Public controls never read Keychain or attach stored credentials.
            let transport = HubAPITransport(useStoredCredential: false)
            let client = HubDiscoveryClient(transport: transport)
            var shortlistQuery = HubQuery(); shortlistQuery.shortlistOnly = true
            let shortlist = try await client.shortlist(shortlistQuery)
            try require(shortlist.models.filter { !$0.experimental }.map(\.id) == HubShortlist.recommended, "Live recommended shortlist metadata failed")
            try require(Set(shortlist.models.map(\.id) + shortlist.unavailableRepositories) == Set(HubShortlist.recommended + HubShortlist.experimental) && Set(shortlist.models.map(\.id)).isDisjoint(with:shortlist.unavailableRepositories), "Live shortlist omitted or duplicated a result/failure")
            try require(shortlist.models.filter(\.experimental).allSatisfy { HubShortlist.experimental.contains($0.id) } && shortlist.cursors.isEmpty, "Live shortlist experimental labels or pagination failed")
            observations.append(["unavailableShortlistRepositories":shortlist.unavailableRepositories,"shortlist":shortlist.models.map { model in ["id":model.id,"runtimes":HubRuntime.allCases.filter { model.runtimes.contains($0) }.map(\.rawValue),"experimental":model.experimental] as [String:Any] }])
            passed.append("public-exact-shortlist-repositories-format-tags-and-experimental-distinction")
            for runtime in HubRuntime.allCases {
                var query = HubQuery(); query.runtimes = [runtime]; query.sort = .downloads
                let first = try await client.search(query, limit: 2)
                try require(first.models.count == 2 && first.unavailableRuntimes.isEmpty && first.cursors.count == 1, "Live runtime first page failed")
                let second = try await client.search(query, cursors: first.cursors, limit: 2)
                try require(second.models.count == 2 && Set(first.models.map(\.id)).isDisjoint(with: second.models.map(\.id)), "Live cursor did not advance")
                observations.append(["runtime": runtime.rawValue, "first": first.models.map(\.id), "second": second.models.map(\.id), "cursorAdvanced": true])
                passed.append("public-\(runtime.rawValue)-first-and-second-page")
            }
            var query = HubQuery(); query.runtimes = [.gguf]; query.author = "LiquidAI"; query.text = "LFM"; query.task = .chat; query.hideGated = true; query.maximumParametersBillions = 2
            let filtered = try await client.search(query, limit: 5)
            try require(!filtered.models.isEmpty && filtered.models.allSatisfy { $0.owner == "LiquidAI" && !$0.gated && $0.pipelineTag == "text-generation" && ($0.namedParametersBillions.map { $0 <= 2 } ?? true) }, "Live combined filters or known size hints failed")
            observations.append(["combinedFilterRepositories": filtered.models.map(\.id)])
            passed.append("public-author-search-task-access-size-query")
            query.organisationsOnly = true
            let organisations = try await client.search(query, limit: 2)
            try require(!organisations.models.isEmpty && organisations.models.allSatisfy { $0.owner == "LiquidAI" }, "Live organisation classification failed")
            passed.append("public-organisation-avatar-classification")
            let details = try await HubClient.details(filtered.models[0].id, transport: transport)
            try require(details.sha.count == 40 && details.siblings.contains { $0.rfilename.hasSuffix(".gguf") }, "Live pinned detail metadata failed")
            observations.append(["detailsRepository": details.id, "detailsRevision": details.sha, "fileCount": details.siblings.count])
            passed.append("public-pinned-revision-and-file-metadata")
            let pinnedFile = HubDetails.File(rfilename: "Qwen3-0.6B-Q4_K_M.gguf", size: 396705472,
                lfs: .init(sha256: "ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a", size: 396705472))
            let pinned = HubDetails(id: "unsloth/Qwen3-0.6B-GGUF", sha: "50968a4468ef4233ed78cd7c3de230dd1d61a56b", siblings: [pinnedFile])
            let selected = try HubClient.gguf(pinned, file: pinnedFile)
            let range = try HubGGUFRangeSource(model: selected, useStoredCredential: false)
            let metadata = try await GGUFHeaderParser(source: range).parse()
            try require(metadata.architecture == "qwen3" && metadata.blocks == 28 && metadata.keyWidth == 128 && metadata.stoppedAtTokenizer,
                        "Actual pinned GGUF header geometry failed")
            try require(metadata.f16KVBytes(context: 2048) == 234881024 && metadata.fetchedBytes <= 262144, "Actual header cache estimate or read bound failed")
            let total = await range.totalBytes
            try require(total == 396705472, "Pinned GGUF range size did not match metadata")
            observations.append(["repository": pinned.id, "revision": pinned.sha, "file": pinnedFile.rfilename,
                "architecture": metadata.architecture, "blocks": metadata.blocks, "trainingContext": metadata.trainingContext,
                "headerFetchedBytes": metadata.fetchedBytes, "fileBytes": total ?? 0, "f16KVBytesAt2048": metadata.f16KVBytes(context: 2048) ?? -1])
            passed.append("actual-public-pinned-gguf-bounded-range-header-and-cache-geometry")
            let compiledDetails = try await HubClient.details("experimentalmachines/Qwen2.5-1.5B-Instruct-ExecuTorch",revision:"0a912670f4bf6039d0192cc420960039bff0d402",transport:transport)
            let compiledFile = try compiledDetails.siblings.first { $0.rfilename == "xnnpack/Qwen2.5-1.5B-Instruct-8da4w-2k.pte" }.unwrap("Pinned compiled weights missing")
            let compiled = try await HubClient.compiled(compiledDetails,file:compiledFile,useStoredCredential:false)
            try require(compiled.family == "qwen25" && compiled.files.count == 3 && compiled.files.last?.sha256 == "be2c11bbe75269f03a95b0407f6bcb976b7282daf259f522850281e614f711dd", "Actual compiled metadata selection failed")
            try require(compiled.files[0].gitBlobSHA1 != nil && compiled.files[1].gitBlobSHA1 != nil && compiled.files[2].gitBlobSHA1 == nil,"Git blobs and LFS content hashes were not distinguished")
            observations.append(["compiledRepository":compiledDetails.id,"compiledRevision":compiledDetails.sha,"family":compiled.family ?? "","components":compiled.files.map { ["path":$0.path,"bytes":$0.bytes ?? -1,"sha256":$0.sha256 ?? "","gitBlobSHA1":$0.gitBlobSHA1 ?? ""] }])
            passed.append("actual-public-pinned-compiled-config-git-checksum-and-canonical-components")
        } else {
            for url in ["http://huggingface.co/api/models", "https://huggingface.co.evil.example/api/models", "https://a:b@huggingface.co/api/models", "https://huggingface.co:444/api/models", "https://huggingface.co/models"] {
                try require(!HubAPITransport.allowed(URL(string: url)!), "Unsafe API redirect admitted")
            }
            try require(HubAPITransport.allowed(URL(string: "https://huggingface.co/api/models?search=Cedar")!), "Public API refused")
            passed.append("actual-api-transport-host-scheme-port-credential-and-path-boundary")
            var query = HubQuery(); query.runtimes = [.gguf]
            let scripted = ScriptedHub([.init(ids: ["org/first"], cursor: "one"), .init(fail: true), .init(ids: ["org/first", "org/second"], cursor: "two"), .init(ids: ["org/third"], cursor: "one")])
            let controller = DiscoveryController(client: HubDiscoveryClient(transport: scripted))
            controller.search(query); try await idle(controller)
            try require(controller.models.map(\.id) == ["org/first"] && controller.hasMore && controller.error == nil, "First-page state failed")
            passed.append("controller-first-page-and-continuation")
            controller.loadMore(); controller.loadMore(); try await idle(controller)
            let callsAfterFailure = await scripted.calls
            try require(controller.models.map(\.id) == ["org/first"] && controller.hasMore && controller.error != nil && callsAfterFailure.count == 2, "Failed append erased results or double-submitted")
            passed.append("controller-failed-page-preserves-results-cursor-and-single-inflight-request")
            controller.retry(); try await idle(controller)
            try require(controller.models.map(\.id) == ["org/first", "org/second"] && controller.error == nil && controller.hasMore, "Retry did not merge unique results")
            passed.append("controller-page-retry-deduplicates-and-clears-error")
            controller.loadMore(); try await idle(controller)
            try require(controller.models.map(\.id) == ["org/first", "org/second", "org/third"] && !controller.hasMore, "Cross-page cursor cycle remained live")
            passed.append("controller-cross-page-cursor-cycle-stops")
            let delayed = ScriptedHub([.init(ids: ["org/stale"], delay: 300_000_000), .init(ids: ["org/current"])])
            let changing = DiscoveryController(client: HubDiscoveryClient(transport: delayed))
            query.text = "old"; changing.search(query)
            for _ in 0..<100 { if !(await delayed.calls).isEmpty { break }; try await Task.sleep(nanoseconds: 1_000_000) }
            query.text = "new"; changing.search(query); try await idle(changing)
            try await Task.sleep(nanoseconds: 350_000_000)
            try require(changing.models.map(\.id) == ["org/current"] && changing.query.text == "new" && changing.error == nil, "Canceled search overwrote current results")
            passed.append("controller-replacement-search-refuses-stale-uncancellable-response")
            let cancelFixture = ScriptedHub([.init(ids: ["org/after-cancel"], delay: 100_000_000)])
            let cancelled = DiscoveryController(client: HubDiscoveryClient(transport: cancelFixture))
            cancelled.search(query)
            for _ in 0..<100 { if !(await cancelFixture.calls).isEmpty { break }; try await Task.sleep(nanoseconds: 1_000_000) }
            cancelled.cancel(); try await Task.sleep(nanoseconds: 150_000_000)
            try require(cancelled.models.isEmpty && !cancelled.busy && cancelled.error == nil, "Disappearance cancellation applied late results")
            passed.append("controller-disappearance-cancellation-keeps-idle-state")
            let partial = ScriptedHub([.init(fail: true), .init(ids: ["org/compiled"]), .init(ids: ["org/mlx"])])
            let available = DiscoveryController(client: HubDiscoveryClient(transport: partial))
            query.runtimes = Set(HubRuntime.allCases); available.search(query); try await idle(available)
            try require(available.models.count == 2 && available.unavailableRuntimes == [.gguf] && available.error == nil, "Partial search hid failure or successful results")
            passed.append("controller-partial-runtime-failure-remains-visible")
            do { _ = try await HubClient.details("../escape", transport: partial); throw CheckFailure(message: "Invalid details ID admitted") }
            catch is ModelError {}
            passed.append("actual-detail-client-rejects-invalid-repository-before-transport")
            let detailHub = PinnedDetailsHub()
            let pin = String(repeating: "a", count: 40)
            let pinnedDetails = try await HubClient.details("org/model", revision: pin, transport: detailHub)
            let detailRequests = await detailHub.calls
            try require(pinnedDetails.sha == pin && detailRequests.count == 1 && detailRequests[0].path == "/api/models/org/model/revision/\(pin)", "Pinned details used a mutable branch or wrong revision")
            passed.append("actual-detail-client-requests-and-validates-exact-pinned-revision")
            for invalid in ["../main", "v1", String(repeating: "g", count: 40)] {
                do { _ = try await HubClient.details("org/model", revision: invalid, transport: detailHub); throw CheckFailure(message: "Invalid detail revision admitted") } catch is ModelError { }
            }
            try require(await detailHub.calls.count == 1, "Invalid revision reached the transport")
            do { _ = try await HubClient.details("org/model", revision: String(repeating: "b", count: 40), transport: detailHub); throw CheckFailure(message: "Returned revision mismatch admitted") } catch is ModelError { }
            passed.append("actual-detail-client-refuses-invalid-revisions-before-transport-and-response-pin-mismatch")
            let revision = String(repeating: "a", count: 40)
            let canonical = HubDetails.File(rfilename: "model-Q4_K_M.gguf", size: 1000, lfs: .init(sha256: String(repeating: "B", count: 64), size: 1000))
            let details = HubDetails(id: "org/model", sha: revision, siblings: [canonical])
            let forged = HubDetails.File(rfilename: canonical.rfilename, size: 1, lfs: .init(sha256: String(repeating: "c", count: 64), size: 1))
            let selected = try HubClient.gguf(details, file: forged)
            try require(selected.files[0].bytes == 1000 && selected.files[0].sha256 == String(repeating: "b", count: 64), "Caller replaced canonical file metadata")
            passed.append("actual-file-selection-uses-canonical-size-and-normalized-published-hash")
            for invalid in [
                HubDetails(id: "../escape", sha: revision, siblings: [canonical]),
                HubDetails(id: "org/model", sha: "main", siblings: [canonical]),
                HubDetails(id: "org/model", sha: revision, siblings: [canonical, canonical]),
                HubDetails(id: "org/model", sha: revision, siblings: [])] {
                do { _ = try HubClient.gguf(invalid, file: canonical); throw CheckFailure(message: "Invalid pinned selection admitted") } catch is ModelError { }
            }
            for path in ["../escape.gguf", "mmproj-model.gguf", "model-00001-of-00002.gguf", "model-LoRA.gguf", "model.pte"] {
                let file = HubDetails.File(rfilename: path, size: 1000)
                do { _ = try HubClient.gguf(.init(id: "org/model", sha: revision, siblings: [file]), file: file); throw CheckFailure(message: "Unsafe or auxiliary file admitted") } catch is ModelError { }
            }
            for invalidFile in [HubDetails.File(rfilename: canonical.rfilename, size: -1), HubDetails.File(rfilename: canonical.rfilename, size: 1000, lfs: .init(sha256: "invalid", size: 1000))] {
                do { _ = try HubClient.gguf(.init(id: "org/model", sha: revision, siblings: [invalidFile]), file: invalidFile); throw CheckFailure(message: "Invalid file metadata admitted") } catch is ModelError { }
            }
            passed.append("actual-file-selection-rejects-unsafe-unlisted-duplicate-unpinned-auxiliary-and-invalid-metadata")
            let projector = HubDetails.File(rfilename:"mmproj-model.gguf",size:200,lfs:.init(sha256:String(repeating:"C",count:64),size:200))
            let pairedDetails = HubDetails(id:details.id,sha:revision,siblings:[canonical,projector])
            let forgedProjector = HubDetails.File(rfilename:projector.rfilename,size:1,lfs:.init(sha256:String(repeating:"d",count:64),size:1))
            let pair = try HubClient.gguf(pairedDetails,file:forged,projector:forgedProjector)
            try require(pair.files.count == 2 && pair.files[1].bytes == 200 && pair.files[1].sha256 == String(repeating:"c",count:64) && pair.files[1].url?.path.contains("/resolve/" + revision + "/") == true,"Projector pair did not use canonical pinned metadata")
            passed.append("projector-pair-uses-canonical-published-size-hash-and-exact-revision")
            for candidate in [HubDetails.File(rfilename:"../mmproj.gguf",size:200,lfs:projector.lfs),HubDetails.File(rfilename:"mmproj-model.gguf",size:0,lfs:nil),HubDetails.File(rfilename:"mmproj-model.gguf",size:200,lfs:nil),HubDetails.File(rfilename:"mmproj-model.gguf",size:200,lfs:.init(sha256:"invalid",size:200)),canonical] {
                do { _ = try HubClient.gguf(.init(id:details.id,sha:revision,siblings:[canonical,candidate]),file:canonical,projector:candidate); throw CheckFailure(message:"Unsafe projector admitted") } catch is ModelError { }
            }
            do { _ = try HubClient.gguf(details,file:canonical,projector:projector); throw CheckFailure(message:"Unlisted projector admitted") } catch is ModelError { }
            passed.append("projector-pair-refuses-unsafe-unlisted-duplicate-nonprojector-or-unverified-companions")
            let configuration = URLSessionConfiguration.ephemeral
            let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
            var original = URLRequest(url: selected.files[0].url!)
            original.setValue("Bearer synthetic-test-value", forHTTPHeaderField: "Authorization")
            original.setValue("synthetic-cookie", forHTTPHeaderField: "Cookie")
            original.setValue("bytes=0-127", forHTTPHeaderField: "Range")
            let task = session.dataTask(with: original)
            let guardDelegate = HubGGUFRedirectGuard()
            let response = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
            var redirected = original; redirected.url = URL(string: "https://us.aws.cdn.hf.co/file")!
            var observed: URLRequest?
            guardDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { observed = $0 }
            try require(observed?.value(forHTTPHeaderField: "Authorization") == nil && observed?.value(forHTTPHeaderField: "Cookie") == nil && observed?.value(forHTTPHeaderField: "Range") == "bytes=0-127", "Redirect leaked credentials or lost byte range")
            for _ in 0..<5 { guardDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { observed = $0 } }
            try require(observed == nil, "Sixth header redirect was admitted")
            redirected.url = URL(string: "https://example.com/file")!
            HubGGUFRedirectGuard().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { observed = $0 }
            try require(observed == nil, "External header redirect was admitted")
            passed.append("actual-header-redirect-delegate-strips-credentials-preserves-range-and-bounds-hosts-and-hops")
            passed += try await compiledSelectionChecks()
        }
        let proof: [String: Any] = ["status": "host-verified", "mode": mode, "passedChecks": passed, "observedAtUTC": ISO8601DateFormatter().string(from: Date()), "observations": observations,
            "limitations": mode == "live" ? ["Real public Mac HTTPS requests without Keychain credentials, including a partial pinned GGUF header. No complete model download/checksum verification, iPhone UI, loading, inference, measured memory-fit or gated credential test."] : ["Actual discovery controller, file builder and redirect delegate with scripted Mac responses. No UIKit rendering, phone execution, real requests or model compatibility claim."]]
        try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
    static func compiledSelectionChecks() async throws -> [String] {
        let data = try JSONSerialization.data(withJSONObject:["runtime":"executorch","runtime_version":"1.4.0","backend":"xnnpack","tokenizer":"tokenizer.json","source_model":"Qwen/Qwen2.5-1.5B-Instruct","variants":[["file":"model.pte","context":2048,"size_bytes":1000,"sha256":String(repeating:"b",count:64)]]])
        var hash = Insecure.SHA1(); hash.update(data:Data("blob \(data.count)\0".utf8)); hash.update(data:data)
        let git = hash.finalize().map { String(format:"%02x",$0) }.joined()
        let config = HubDetails.File(rfilename:"xnnpack/config.json",size:Int64(data.count),blobId:git)
        let weights = HubDetails.File(rfilename:"xnnpack/model.pte",size:1000,lfs:.init(sha256:String(repeating:"b",count:64),size:1000),blobId:String(repeating:"f",count:40))
        let tokenizer = HubDetails.File(rfilename:"tokenizer.json",size:6,blobId:"ce013625030ba8dba906f756967f9e9ca394464a")
        let details = HubDetails(id:"org/model",sha:String(repeating:"a",count:40),siblings:[config,weights,tokenizer])
        let probe = CompiledMetadataProbe(data)
        let forged = HubDetails.File(rfilename:weights.rfilename,size:1,lfs:.init(sha256:String(repeating:"d",count:64),size:1))
        let selected = try await HubClient.compiled(details,file:forged,readMetadata:{ await probe.read($0) })
        let requests = await probe.requests
        try require(requests.count == 1 && requests[0].files.count == 1 && requests[0].files[0].url?.path == "/org/model/resolve/\(details.sha)/xnnpack/config.json","Compiled metadata request did not use canonical pin")
        try require(selected.files.last?.bytes == 1000 && selected.files.last?.sha256 == String(repeating:"b",count:64) && selected.files.last?.gitBlobSHA1 == nil && selected.files[1].gitBlobSHA1 == tokenizer.blobId,"Caller metadata or LFS pointer replaced content identity")
        let rejected = CompiledMetadataProbe(data)
        for invalid in [HubDetails(id:"../escape",sha:details.sha,siblings:details.siblings),HubDetails(id:details.id,sha:"main",siblings:details.siblings),HubDetails(id:details.id,sha:details.sha,siblings:[config,weights,weights,tokenizer]),HubDetails(id:details.id,sha:details.sha,siblings:[weights,tokenizer]),HubDetails(id:details.id,sha:details.sha,siblings:[.init(rfilename:config.rfilename,size:1_048_577,blobId:git),weights,tokenizer])] {
            do { _ = try await HubClient.compiled(invalid,file:weights,readMetadata:{ await rejected.read($0) }); throw CheckFailure(message:"Invalid compiled preflight reached selection") } catch is ModelError { }
        }
        try require(await rejected.requests.isEmpty,"Invalid compiled pin/config reached transport")
        let corrupt = CompiledMetadataProbe(Data(data.reversed()))
        do { _ = try await HubClient.compiled(details,file:weights,readMetadata:{ await corrupt.read($0) }); throw CheckFailure(message:"Corrupt compiled config admitted") } catch is ModelError { }
        let delayed = CompiledMetadataProbe(data,delay:100_000_000)
        let operation = Task { try await HubClient.compiled(details,file:weights,readMetadata:{ await delayed.read($0) }) }
        for _ in 0..<100 { if !(await delayed.requests).isEmpty { break }; try await Task.sleep(nanoseconds:1_000_000) }
        operation.cancel()
        do { _ = try await operation.value; throw CheckFailure(message:"Cancelled metadata response produced a model") } catch is CancellationError { }
        return ["compiled-selection-requests-canonical-pinned-config-and-refuses-forged-file-and-lfs-pointer-hashes","compiled-preflight-refuses-invalid-pin-duplicate-file-missing-or-oversized-config-before-transport","compiled-config-checksum-rejects-tampered-response","compiled-selection-refuses-late-response-after-cancellation"]
    }
}
private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped { guard let value = self else { throw CheckFailure(message:message) }; return value }
}

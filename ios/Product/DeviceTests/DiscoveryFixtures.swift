import Foundation
import OpenWeightsCore

actor DiscoveryFixtureTransport: HubDiscoveryTransport {
    private var step = 0
    private(set) var requests: [URL] = []
    func get(_ url: URL) async throws -> HubAPIResponse {
        requests.append(url); step += 1
        if step == 2 { throw URLError(.timedOut) }
        let ids = step == 1 ? ["org/first"] : ["org/first", "org/second"]
        let data = try JSONSerialization.data(withJSONObject: ids.map { ["id": $0] })
        return HubAPIResponse(status: 200, data: data, link: step == 1 ? "<https://huggingface.co/api/models?cursor=native-next>; rel=next" : nil)
    }
}

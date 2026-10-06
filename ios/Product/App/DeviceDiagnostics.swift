import Foundation
import Combine
import OpenWeightsCore

struct ComputeDiagnostics: Decodable, Equatable {
    struct Device: Decodable, Equatable, Identifiable {
        let id: String
        let description: String
        let kind: String
        let totalMemoryBytes: UInt64
    }
    let devices: [Device]
    let engineInfo: String
    var features: EngineFeatures { EngineFeatures(info: engineInfo) }
}
struct DeviceDiagnosticsSnapshot {
    let compute: ComputeDiagnostics
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let appHeadroomBytes: UInt64?
    let freeStorageBytes: Int64?
    let system: String
    let lowPowerMode: Bool
    let thermalState: ProcessInfo.ThermalState
    let observedAt: Date
}
@MainActor final class DeviceDiagnosticsController: ObservableObject {
    @Published private(set) var snapshot: DeviceDiagnosticsSnapshot?
    @Published private(set) var failure: String?
    func refresh() {
        do {
            let data = try JSONSerialization.data(withJSONObject: OWRuntimeSession.computeDiagnostics())
            let compute = try JSONDecoder().decode(ComputeDiagnostics.self, from: data)
            let info = ProcessInfo.processInfo
            let headroom = OWRuntimeSession.availableMemoryBytes().uint64Value
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let storage = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            snapshot = DeviceDiagnosticsSnapshot(compute: compute, processorCount: info.activeProcessorCount,
                physicalMemoryBytes: info.physicalMemory, appHeadroomBytes: headroom > 0 ? headroom : nil,
                freeStorageBytes: storage, system: info.operatingSystemVersionString,
                lowPowerMode: info.isLowPowerModeEnabled, thermalState: info.thermalState, observedAt: Date())
            failure = nil
        } catch { failure = "Device information could not be read. Refresh to retry." }
    }
}

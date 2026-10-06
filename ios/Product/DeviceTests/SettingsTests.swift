import XCTest
import UIKit
import SwiftUI
import Security
import Metal
import OpenWeightsCore
@testable import OpenWeights

private actor SettingsIdentityFixture: HubIdentityVerifying {
    enum Result { case accepted, rejected, unavailable }
    let result: Result
    var held: Bool
    private(set) var callCount = 0
    init(_ result: Result, held: Bool = false) { self.result = result; self.held = held }
    func release() { held = false }
    func verify(_ token: String) async throws -> String {
        callCount += 1
        while held { try await Task.sleep(nanoseconds: 10_000_000) }
        switch result {
        case .accepted: return "fixture-account"
        case .rejected: throw HubIdentityFailure.rejected
        case .unavailable: throw NSError(domain: token,code:1,userInfo:[NSLocalizedDescriptionKey: token])
        }
    }
}
private struct FailingSettingsVault: HubCredentialStorage {
    let base: KeychainHubCredentialStore
    var failRead = false
    var failWrite = false
    var failRemove = false
    func token() throws -> String? {
        if failRead { throw URLError(.cannotOpenFile) }
        return try base.token()
    }
    func save(_ token: String) throws {
        if (token.isEmpty && failRemove) || (!token.isEmpty && failWrite) {
            throw NSError(domain: token,code:1,userInfo:[NSLocalizedDescriptionKey: token])
        }
        try base.save(token)
    }
}

extension ProductTests {
    @MainActor func testNativeHubCredentialKeychainVerificationLifecycle() async throws {
        let service = "org.experimentalmachines.openweights.settings-fixture." + UUID().uuidString
        let vault = KeychainHubCredentialStore(service:service)
        let firstToken = "fixture-" + UUID().uuidString, secondToken = "fixture-" + UUID().uuidString
        var checks: [String] = [], completed = false
        defer {
            try? vault.save("")
            let payload: [String:Any] = ["purpose":"native-Hugging-Face-credential-Keychain-controller-lifecycle","completed":completed,"checks":checks,
                "limitations":["Synthetic fixture credentials use an isolated Keychain service. The user's real credential is neither read nor changed.","Accepted account, transient failure and held races use controlled verifier outcomes. Live rejection is a separate test. No valid live credential or gated download proof.","No token values, Keychain data, account identities or response bodies are attached. No UI gesture or process-termination claim."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Credential lifecycle checks"; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertNil(try vault.token())
        let accepted = SettingsIdentityFixture(.accepted)
        let controller = HubCredentialController(vault:vault,verifier:accepted); controller.refresh()
        XCTAssertFalse(controller.hasToken)
        let saved = await controller.save("  " + firstToken + "\n"); XCTAssertTrue(saved)
        XCTAssertTrue(controller.hasToken); XCTAssertFalse(controller.busy); XCTAssertEqual(controller.status,"Verified as fixture-account")
        XCTAssertTrue(try vault.token() == firstToken)
        let reopen = KeychainHubCredentialStore(service:service); XCTAssertTrue(try reopen.token() == firstToken)
        var attributes: CFTypeRef?
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
            kSecAttrAccount as String:"token",kSecAttrSynchronizable as String:false,kSecReturnAttributes as String:true]
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary,&attributes),errSecSuccess)
        let metadata = try XCTUnwrap(attributes as? [String:Any])
        XCTAssertEqual(metadata[kSecAttrAccessible as String] as? String,kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertFalse(metadata[kSecAttrSynchronizable as String] as? Bool ?? false)
        checks.append("saved-trimmed-verified-reopened-device-only-nonsynchronizing-Keychain")
        let replacementSaved = await controller.save(secondToken); XCTAssertTrue(replacementSaved)
        XCTAssertTrue(try reopen.token() == secondToken); checks.append("existing-Keychain-item-updated")
        let legacyQuery: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
            kSecAttrAccount as String:"token",kSecAttrSynchronizable as String:false]
        let legacyBytes = Data(("  " + secondToken + "\n").utf8)
        XCTAssertEqual(SecItemUpdate(legacyQuery as CFDictionary,[kSecValueData as String:legacyBytes] as CFDictionary),errSecSuccess)
        XCTAssertTrue(try reopen.token() == secondToken)
        var legacyRead: CFTypeRef?; var dataQuery = legacyQuery; dataQuery[kSecReturnData as String] = true
        XCTAssertEqual(SecItemCopyMatching(dataQuery as CFDictionary,&legacyRead),errSecSuccess)
        XCTAssertTrue((legacyRead as? Data) == legacyBytes)
        checks.append("legacy-whitespace-normalized-on-read-without-rewriting-bytes")
        let invalidSaved = await controller.save("bad\r\nheader"); XCTAssertFalse(invalidSaved)
        XCTAssertTrue(try reopen.token() == secondToken)
        checks.append("header-injection-refused-existing-value-preserved")
        let unavailable = HubCredentialController(vault:vault,verifier:SettingsIdentityFixture(.unavailable))
        let offlineSaved = await unavailable.save(firstToken); XCTAssertTrue(offlineSaved)
        XCTAssertTrue(unavailable.hasToken); XCTAssertTrue(try reopen.token() == firstToken)
        XCTAssertFalse(unavailable.status?.contains(firstToken) ?? true); checks.append("network-failure-keeps-saved-value-redacts-error")
        let rejected = HubCredentialController(vault:vault,verifier:SettingsIdentityFixture(.rejected))
        let rejectedSaved = await rejected.save(secondToken); XCTAssertTrue(rejectedSaved)
        XCTAssertFalse(rejected.hasToken); XCTAssertNil(try reopen.token()); checks.append("auth-rejection-removes-rejected-value")
        try vault.save(firstToken)
        let neverCheck = SettingsIdentityFixture(.accepted)
        let writeFailure = HubCredentialController(vault:FailingSettingsVault(base:vault,failWrite:true),verifier:neverCheck)
        writeFailure.refresh(); let failedSave = await writeFailure.save(secondToken); XCTAssertFalse(failedSave)
        XCTAssertTrue(writeFailure.hasToken); XCTAssertTrue(try reopen.token() == firstToken)
        XCTAssertFalse(writeFailure.status?.contains(secondToken) ?? true)
        let neverCalled = await neverCheck.callCount; XCTAssertEqual(neverCalled,0)
        checks.append("failed-write-preserves-previous-value-and-skips-network")
        let removeFailure = HubCredentialController(vault:FailingSettingsVault(base:vault,failRemove:true),verifier:SettingsIdentityFixture(.rejected))
        let failureSaved = await removeFailure.save(secondToken); XCTAssertTrue(failureSaved)
        XCTAssertTrue(removeFailure.hasToken); XCTAssertTrue(try reopen.token() == secondToken)
        XCTAssertFalse(removeFailure.remove()); XCTAssertTrue(try reopen.token() == secondToken)
        checks.append("failed-removal-keeps-value-and-discloses-failure")
        let readFailure = HubCredentialController(vault:FailingSettingsVault(base:vault,failRead:true),verifier:neverCheck)
        readFailure.refresh(); XCTAssertNotNil(readFailure.status); XCTAssertTrue(try reopen.token() == secondToken)
        checks.append("failed-read-preserves-Keychain")
        let held = SettingsIdentityFixture(.rejected,held:true)
        let pending = HubCredentialController(vault:vault,verifier:held)
        let task = Task { await pending.save(firstToken) }
        for _ in 0..<200 {
            if await held.callCount == 1 { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        XCTAssertTrue(pending.busy)
        let overlap = await pending.save(secondToken); XCTAssertFalse(overlap); XCTAssertFalse(pending.remove())
        XCTAssertTrue(try reopen.token() == firstToken)
        // Another settings instance may outlive a navigation transition.
        let newer = HubCredentialController(vault:vault,verifier:SettingsIdentityFixture(.accepted))
        let newerSaved = await newer.save(secondToken); XCTAssertTrue(newerSaved)
        await held.release(); let oldFinished = await task.value; XCTAssertTrue(oldFinished)
        XCTAssertTrue(try reopen.token() == secondToken); XCTAssertTrue(pending.hasToken)
        XCTAssertTrue(pending.status?.contains("changed") ?? false)
        checks.append("overlap-refused-and-stale-rejection-cannot-delete-newer-save")
        XCTAssertTrue(newer.remove()); XCTAssertNil(try reopen.token()); XCTAssertTrue(newer.remove())
        checks.append("explicit-removal-and-idempotent-empty-removal")
        let heldOffline = SettingsIdentityFixture(.unavailable,held:true)
        let offlinePending = HubCredentialController(vault:vault,verifier:heldOffline)
        let offlineTask = Task { await offlinePending.save(firstToken) }
        for _ in 0..<200 {
            if await heldOffline.callCount == 1 { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        XCTAssertTrue(offlinePending.busy); newer.refresh(); XCTAssertTrue(newer.remove())
        await heldOffline.release(); let offlineFinished = await offlineTask.value; XCTAssertTrue(offlineFinished)
        XCTAssertFalse(offlinePending.hasToken); XCTAssertNil(try reopen.token())
        XCTAssertTrue(offlinePending.status?.contains("changed") ?? false)
        checks.append("late-network-failure-cannot-report-an-already-removed-value-as-saved")
        completed = checks.count == 12
        XCTAssertTrue(completed)
    }

    @MainActor func testNativeHubIdentityRejectionFromLiveHub() async throws {
        let vault = KeychainHubCredentialStore(service:"org.experimentalmachines.openweights.live-rejection-fixture." + UUID().uuidString)
        defer { try? vault.save("") }
        let invalid = "openweights-invalid-fixture-" + UUID().uuidString
        let controller = HubCredentialController(vault:vault)
        let saved = await controller.save(invalid)
        XCTAssertTrue(saved); XCTAssertFalse(controller.hasToken); XCTAssertNil(try vault.token())
        XCTAssertTrue(controller.status?.contains("rejected") ?? false)
        let payload: [String:Any] = ["purpose":"native-live-Hugging-Face-identity-rejection","completed":saved && !controller.hasToken,
            "endpoint":"https://huggingface.co/api/whoami-v2","rejectedCredentialRemoved":try vault.token() == nil,
            "limitations":["A generated invalid fixture value is sent to the exact Hub identity endpoint. No user's real token is read or changed, and no response body or credential is retained.","This verifies rejection handling, not a valid live account or gated-model access."]]
        let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name = "Live credential rejection"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testNativeComputeAndAppearanceSettingsRendering() async throws {
        let diagnostics = DeviceDiagnosticsController(); diagnostics.refresh()
        let snapshot = try XCTUnwrap(diagnostics.snapshot); XCTAssertNil(diagnostics.failure)
        XCTAssertTrue(snapshot.compute.devices.contains { $0.kind == "Processor" })
        XCTAssertFalse(snapshot.compute.features.backends.isEmpty)
        let hasMetal = snapshot.compute.features.backends.contains { $0.lowercased() == "mtl" }
        if MTLCreateSystemDefaultDevice() != nil { XCTAssertTrue(hasMetal) }
        XCTAssertGreaterThan(snapshot.processorCount,0); XCTAssertGreaterThan(snapshot.physicalMemoryBytes,0)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.appHeadroomBytes),0)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.freeStorageBytes),0)
        let defaults = UserDefaults.standard, previousAppearance = defaults.object(forKey:"appearance")
        defer { if let previousAppearance { defaults.set(previousAppearance,forKey:"appearance") } else { defaults.removeObject(forKey:"appearance") } }
        for value in ["light","dark","system"] {
            defaults.set(value,forKey:"appearance")
            XCTAssertEqual(UserDefaults.standard.string(forKey:"appearance"),value)
        }
        XCTAssertEqual(OWTheme.preferredColorScheme("light"),.light)
        XCTAssertEqual(OWTheme.preferredColorScheme("dark"),.dark)
        XCTAssertNil(OWTheme.preferredColorScheme("system")); XCTAssertNil(OWTheme.preferredColorScheme("unknown"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        var styles: [String] = []
        for style in ["light","dark"] {
            defaults.set(style,forKey:"appearance")
            let selected = try XCTUnwrap(OWTheme.preferredColorScheme(UserDefaults.standard.string(forKey:"appearance")!))
            window.rootViewController = UIHostingController(rootView:NavigationStack {
                Form { DeviceDiagnosticsSections(diagnostics:diagnostics) }.navigationTitle("Device information")
                    .scrollContentBackground(.hidden).background(OWTheme.canvas)
            }.font(OWTheme.interface()).foregroundStyle(OWTheme.text).tint(OWTheme.text).preferredColorScheme(selected))
            window.makeKeyAndVisible(); try await Task.sleep(nanoseconds:1_000_000_000)
            XCTAssertEqual(window.rootViewController?.view.traitCollection.userInterfaceStyle,style == "light" ? .light : .dark)
            let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image); attachment.name = "Compute and device settings " + style; attachment.lifetime = .keepAlways; add(attachment)
            styles.append(style)
        }
        let payload: [String:Any] = ["purpose":"native-compute-diagnostics-and-appearance-settings","completed":styles.count == 2,
            "devices":snapshot.compute.devices.map { ["id":$0.id,"kind":$0.kind,"description":$0.description,"reportedMemoryBytes":$0.totalMemoryBytes] },
            "backends":snapshot.compute.features.backends,"enabledFeatures":snapshot.compute.features.enabled,
            "processorCount":snapshot.processorCount,"physicalMemoryBytes":snapshot.physicalMemoryBytes,
            "appHeadroomBytes":snapshot.appHeadroomBytes!,"freeStorageBytes":snapshot.freeStorageBytes!,
            "system":snapshot.system,"appearanceModesPersisted":["light","dark","system"],"renderedAppearanceModes":styles,
            "limitations":["Same-process UserDefaults persistence and actual production sections hosted in UIKit. No app-process termination, touch navigation, offscreen-layout or accessibility claim.","GGUF device/feature enumeration does not imply Neural Engine placement, speed or guaranteed model fit. Headroom/storage are point-in-time observations.","The user's prior appearance is restored. No real Hugging Face credential is read or changed."]]
        let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name = "Native settings observations"; attachment.lifetime = .keepAlways; add(attachment)
    }
}

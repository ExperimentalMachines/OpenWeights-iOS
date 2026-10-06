import Foundation
import Combine
import OpenWeightsCore

protocol HubCredentialStorage: Sendable {
    func token() throws -> String?
    func save(_ token: String) throws
}
protocol HubIdentityVerifying: Sendable {
    func verify(_ token: String) async throws -> String
}
struct HubIdentityClient: HubIdentityVerifying {
    func verify(_ token: String) async throws -> String {
        let transport = HubAPITransport(useStoredCredential: false, credential: token)
        let response = try await transport.get(URL(string: "https://huggingface.co/api/whoami-v2")!)
        let account = try HubIdentity.account(response)
        guard !account.contains(token) else { throw HubIdentityFailure.unavailable }
        return account
    }
}

@MainActor final class HubCredentialController: ObservableObject {
    @Published private(set) var hasToken = false
    @Published private(set) var status: String?
    @Published private(set) var busy = false
    private let vault: any HubCredentialStorage
    private let verifier: any HubIdentityVerifying
    init(vault: any HubCredentialStorage = KeychainHubCredentialStore(), verifier: any HubIdentityVerifying = HubIdentityClient()) {
        self.vault = vault; self.verifier = verifier
    }
    func refresh() {
        guard !busy else { return }
        do { hasToken = try vault.token() != nil }
        catch { hasToken = false; status = "Keychain could not read the credential. Existing data was preserved." }
    }
    @discardableResult func save(_ raw: String) async -> Bool {
        // Refuse overlaps so an older verification cannot delete a newer save.
        guard !busy else { return false }
        let token: String
        do { token = try HubIdentity.credential(raw) }
        catch { status = "Enter a nonempty Hugging Face token without spaces or control characters."; return false }
        busy = true; status = nil
        defer { busy = false }
        do { try vault.save(token); hasToken = true }
        catch { status = "Not saved: Keychain could not keep the credential. Existing data was preserved."; return false }
        do {
            let account = try await verifier.verify(token)
            guard try unchanged(token) else { return true }
            status = "Verified as " + account
        } catch HubIdentityFailure.rejected {
            do {
                guard try unchanged(token) else { return true }
                try vault.save(""); hasToken = false; status = "Hugging Face rejected the credential. It was removed. Check your token and access permissions." }
            catch { status = "Hugging Face rejected the credential, but Keychain could not safely remove it. Remove it before retrying." }
        } catch {
            // A network outage does not prove that the stored credential is invalid.
            do { guard try unchanged(token) else { return true } }
            catch { status = "Verification did not finish, and Keychain could not reread the credential. Existing data was preserved."; return true }
            status = "Saved in Keychain, but it could not be verified right now. Retry when Hugging Face is reachable."
        }
        return true
    }
    private func unchanged(_ token: String) throws -> Bool {
        let current = try vault.token(); hasToken = current != nil
        guard current == token else {
            status = "The saved credential changed while verification was running. Save and verify again if needed."
            return false
        }
        return true
    }
    @discardableResult func remove() -> Bool {
        guard !busy else { return false }
        do { try vault.save(""); hasToken = false; status = "Credential removed."; return true }
        catch { status = "Keychain could not remove the credential. Existing data was preserved."; return false }
    }
}

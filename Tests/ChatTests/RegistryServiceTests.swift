import Foundation
import XCTest
@testable import WalletConnectChat
import WalletConnectUtils
import WalletConnectNetworking
import WalletConnectKMS
@testable import TestingUtils

final class RegistryServiceTests: XCTestCase {
    var registryService: RegistryService!
    var identityStorage: IdentityStorage!
    var networkService: IdentityNetwotkServiceMock!
    var networkingInteractor: NetworkingInteractorMock!
    var kms: KeyManagementServiceMock!

    let account = Account("eip155:1:0x1AAe9864337E821f2F86b5D27468C59AA333C877")!
    let privateKey = "4dc0055d1831f7df8d855fc8cd9118f4a85ddc05395104c4cb0831a6752621a8"

    let cacaoStub: Cacao = {
        return Cacao(h: .init(t: ""), p: .init(iss: "", domain: "", aud: "", version: "", nonce: "", iat: "", nbf: "", exp: nil, statement: nil, requestId: nil, resources: nil), s: .init(t: .eip191, s: ""))
    }()

    let inviteKeyStub = "62720d14643acf0f7dd87513b079502f56be414a2f2ea4719342cf088c794173"

    override func setUp() {
        networkingInteractor = NetworkingInteractorMock()
        kms = KeyManagementServiceMock()
        identityStorage = IdentityStorage(keychain: KeychainStorageMock())
        networkService = IdentityNetwotkServiceMock(cacao: cacaoStub, inviteKey: inviteKeyStub)

        let identitySevice = IdentityService(
            keyserverURL: URL(string: "https://www.url.com")!,
            kms: kms,
            storage: identityStorage,
            networkService: networkService,
            iatProvader: DefaultIATProvider(),
            messageFormatter: SIWECacaoFormatter()
        )
        registryService = RegistryService(identityService: identitySevice, networkingInteractor: networkingInteractor, kms: kms, logger: ConsoleLoggerMock())
    }

    func testRegister() async throws {
        let pubKey = try await registryService.register(account: account, onSign: onSign)

        XCTAssertNotNil(identityStorage.getIdentityKey(for: account))
        XCTAssertTrue(networkService.callRegisterIdentity)

        let identityKey = identityStorage.getIdentityKey(for: account)
        XCTAssertEqual(identityKey?.publicKey.hexRepresentation, pubKey)
    }

    func testGoPublic() async throws {
        XCTAssertTrue(networkingInteractor.subscriptions.isEmpty)

        _ = try await registryService.register(account: account, onSign: onSign)
        try await registryService.goPublic(account: account)

        XCTAssertNotNil(identityStorage.getInviteKey(for: account))
        XCTAssertTrue(networkService.callRegisterInvite)

        XCTAssertEqual(networkingInteractor.subscriptions.count, 1)
        XCTAssertNotNil(kms.getPublicKey(for: networkingInteractor.subscriptions[0]))
    }

    func testUnregister() async throws {
        XCTAssertNil(identityStorage.getIdentityKey(for: account))

        _ = try await registryService.register(account: account, onSign: onSign)
        XCTAssertNotNil(identityStorage.getIdentityKey(for: account))

        try await registryService.unregister(account: account, onSign: onSign)
        XCTAssertNil(identityStorage.getIdentityKey(for: account))
        XCTAssertTrue(networkService.callRemoveIdentity)
    }

    func testGoPrivate() async throws {
        let invitePubKey = try AgreementPublicKey(hex: inviteKeyStub)
        try identityStorage.saveInviteKey(invitePubKey, for: account)

        let identityKey = SigningPrivateKey()
        try identityStorage.saveIdentityKey(identityKey, for: account)

        let topic = invitePubKey.rawRepresentation.sha256().toHexString()
        try await networkingInteractor.subscribe(topic: topic)

        try await registryService.goPrivate(account: account)
        XCTAssertNil(identityStorage.getInviteKey(for: account))
        XCTAssertTrue(networkingInteractor.unsubscriptions.contains(topic))
    }

    func testResolve() async throws {
        let inviteKey = try await registryService.resolve(account: account)

        XCTAssertEqual(inviteKey, inviteKeyStub)
    }

    private func onSign(_ message: String) -> SigningResult {
        return .signed(CacaoSignature(t: .eip191, s: ""))
    }
}

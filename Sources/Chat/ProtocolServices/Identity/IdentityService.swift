import Foundation

actor IdentityService {

    private let keyserverURL: URL
    private let kms: KeyManagementServiceProtocol
    private let storage: IdentityStorage
    private let networkService: IdentityNetworking
    private let iatProvader: IATProvider
    private let messageFormatter: SIWECacaoFormatting

    init(
        keyserverURL: URL,
        kms: KeyManagementServiceProtocol,
        storage: IdentityStorage,
        networkService: IdentityNetworking,
        iatProvader: IATProvider,
        messageFormatter: SIWECacaoFormatting
    ) {
        self.keyserverURL = keyserverURL
        self.kms = kms
        self.storage = storage
        self.networkService = networkService
        self.iatProvader = iatProvader
        self.messageFormatter = messageFormatter
    }

    func registerIdentity(account: Account,
        onSign: SigningCallback
    ) async throws -> String {

        if let identityKey = storage.getIdentityKey(for: account) {
            return identityKey.publicKey.hexRepresentation
        }

        let identityKey = SigningPrivateKey()
        let cacao = try await makeCacao(DIDKey: identityKey.publicKey.did, account: account, onSign: onSign)
        try await networkService.registerIdentity(cacao: cacao)

        return try storage.saveIdentityKey(identityKey, for: account).publicKey.hexRepresentation
    }

    func registerInvite(account: Account) async throws -> AgreementPublicKey {

        if let inviteKey = storage.getInviteKey(for: account) {
            return inviteKey
        }

        let inviteKey = try kms.createX25519KeyPair()
        let invitePublicKey = DIDKey(rawData: inviteKey.rawRepresentation)
        let idAuth = try makeIDAuth(account: account, invitePublicKey: invitePublicKey)
        try await networkService.registerInvite(idAuth: idAuth)

        return try storage.saveInviteKey(inviteKey, for: account)
    }

    func unregister(account: Account, onSign: SigningCallback) async throws {
        guard let identityKey = storage.getIdentityKey(for: account)
        else { throw Errors.identityKeyNotFound }

        let cacao = try await makeCacao(DIDKey: identityKey.publicKey.did, account: account, onSign: onSign)
        try await networkService.removeIdentity(cacao: cacao)
        try storage.removeIdentityKey(for: account)
    }

    func goPrivate(account: Account) async throws -> AgreementPublicKey {
        guard let inviteKey = storage.getInviteKey(for: account)
        else { throw Errors.inviteKeyNotFound }

        let invitePublicKey = DIDKey(rawData: inviteKey.rawRepresentation)
        let idAuth = try makeIDAuth(account: account, invitePublicKey: invitePublicKey)
        try await networkService.removeInvite(idAuth: idAuth)
        try storage.removeInviteKey(for: account)

        return inviteKey
    }

    func resolveIdentity(iss: String) async throws -> Account {
        let did = try DIDKey(did: iss).did(prefix: false, variant: .ED25519)
        let cacao = try await networkService.resolveIdentity(publicKey: did)
        return try Account(DIDPKHString: cacao.p.iss)
    }

    func resolveInvite(account: Account) async throws -> String {
        return try await networkService.resolveInvite(account: account.absoluteString)
    }
}

private extension IdentityService {

    enum Errors: Error {
        case identityKeyNotFound
        case inviteKeyNotFound
    }

    func makeCacao(
        DIDKey: String,
        account: Account,
        onSign: SigningCallback
    ) async throws -> Cacao {

        let cacaoHeader = CacaoHeader(t: "eip4361")
        let cacaoPayload = CacaoPayload(
            iss: account.did,
            domain: keyserverURL.host!,
            aud: getAudience(),
            version: getVersion(),
            nonce: getNonce(),
            iat: iatProvader.iat,
            nbf: nil, exp: nil, statement: nil, requestId: nil,
            resources: [DIDKey]
        )

        let result = await onSign(try messageFormatter.formatMessage(from: cacaoPayload))

        switch result {
        case .signed(let cacaoSignature):
            return Cacao(h: cacaoHeader, p: cacaoPayload, s: cacaoSignature)
        case .rejected:
            throw ChatError.signatureRejected
        }
    }

    func makeIDAuth(account: Account, invitePublicKey: DIDKey) throws -> String {
        guard let identityKey = storage.getIdentityKey(for: account)
        else { throw Errors.identityKeyNotFound }
        return try JWTFactory(keyPair: identityKey).createChatInviteJWT(
            sub: invitePublicKey.did(prefix: true, variant: .X25519),
            aud: getAudience(),
            pkh: account.did
        )
    }

    private func getNonce() -> String {
        return Data.randomBytes(count: 32).toHexString()
    }

    private func getVersion() -> String {
        return "1"
    }

    private func getAudience() -> String {
        return keyserverURL.absoluteString
    }
}

import Foundation
import Combine

class InviteService {

    private var publishers = [AnyCancellable]()
    private let keyserverURL: URL
    private let networkingInteractor: NetworkInteracting
    private let identityStorage: IdentityStorage
    private let accountService: AccountService
    private let logger: ConsoleLogging
    private let kms: KeyManagementService
    private let chatStorage: ChatStorage
    private let registryService: RegistryService

    init(
        keyserverURL: URL,
        networkingInteractor: NetworkInteracting,
        identityStorage: IdentityStorage,
        accountService: AccountService,
        kms: KeyManagementService,
        chatStorage: ChatStorage,
        logger: ConsoleLogging,
        registryService: RegistryService
    ) {
        self.kms = kms
        self.keyserverURL = keyserverURL
        self.networkingInteractor = networkingInteractor
        self.identityStorage = identityStorage
        self.accountService = accountService
        self.logger = logger
        self.chatStorage = chatStorage
        self.registryService = registryService
        setUpResponseHandling()
    }

    @discardableResult
    func invite(invite: Invite) async throws -> Int64 {
        // TODO ad storage
        let protocolMethod = ChatInviteProtocolMethod()
        let selfPubKeyY = try kms.createX25519KeyPair()
        let inviteePublicKey = try DIDKey(did: invite.inviteePublicKey)
        let symKeyI = try kms.performKeyAgreement(selfPublicKey: selfPubKeyY, peerPublicKey: inviteePublicKey.hexString)
        let inviteTopic = try AgreementPublicKey(hex: inviteePublicKey.hexString).rawRepresentation.sha256().toHexString()

        // overrides on invite toipic
        try kms.setSymmetricKey(symKeyI.sharedKey, for: inviteTopic)

        let authID = try makeInviteJWT(message: invite.message, inviteeAccount: invite.inviteeAccount, publicKey: DIDKey(rawData: selfPubKeyY.rawRepresentation))
        let payload = InvitePayload(inviteAuth: authID)
        let inviteId = RPCID()
        let request = RPCRequest(method: protocolMethod.method, params: payload, rpcid: inviteId)

        // 2. Proposer subscribes to topic R which is the hash of the derived symKey
        let responseTopic = symKeyI.derivedTopic()

        try kms.setSymmetricKey(symKeyI.sharedKey, for: responseTopic)

        try await networkingInteractor.subscribe(topic: responseTopic)
        try await networkingInteractor.request(request, topic: inviteTopic, protocolMethod: protocolMethod, envelopeType: .type1(pubKey: selfPubKeyY.rawRepresentation))

        let sentInvite = SentInvite(
            id: inviteId.integer,
            message: invite.message,
            inviterAccount: invite.inviterAccount,
            inviteeAccount: invite.inviteeAccount,
            timestamp: Int64(Date().timeIntervalSince1970)
        )

        chatStorage.set(sentInvite: sentInvite, account: invite.inviterAccount)

        logger.debug("invite sent on topic: \(inviteTopic)")

        return inviteId.integer
    }
}

private extension InviteService {

    enum Errors: Error {
        case identityKeyNotFound
    }

    func setUpResponseHandling() {
        networkingInteractor.responseSubscription(on: ChatInviteProtocolMethod())
            .sink { [unowned self] (payload: ResponseSubscriptionPayload<InvitePayload, AcceptPayload>) in
                logger.debug("Invite has been accepted")

                guard
                    let decodedRequest = try? payload.request.decode(),
                    let decodedResponse = try? payload.response.decode()
                else { fatalError() /* TODO: Handle error */ }

                Task(priority: .high) {
                    // TODO: Improve claims parsing
                    let sentInviteId = payload.id.integer
                    let inviterAccount = decodedResponse.account
                    let inviteeAccount = decodedRequest.account
                    let inviterPublicKey = decodedRequest.publicKey
                    let inviteePublicKey = decodedResponse.publicKey

                    // TODO: Implement reject for sentInvite
                    chatStorage.accept(sentInviteId: sentInviteId, account: inviterAccount)

                    try await createThread(
                        selfPubKeyHex: inviterPublicKey,
                        peerPubKey: inviteePublicKey,
                        account: inviterAccount,
                        peerAccount: inviteeAccount
                    )
                }
            }.store(in: &publishers)
    }

    func createThread(selfPubKeyHex: String, peerPubKey: String, account: Account, peerAccount: Account) async throws {
        let selfPubKey = try AgreementPublicKey(hex: selfPubKeyHex)
        let agreementKeys = try kms.performKeyAgreement(selfPublicKey: selfPubKey, peerPublicKey: peerPubKey)
        let threadTopic = agreementKeys.derivedTopic()
        try kms.setSymmetricKey(agreementKeys.sharedKey, for: threadTopic)

        try await networkingInteractor.subscribe(topic: threadTopic)

        let thread = Thread(
            topic: threadTopic,
            selfAccount: account,
            peerAccount: peerAccount
        )

        chatStorage.set(thread: thread, account: account)
        // TODO - remove symKeyI
    }

    func makeInviteJWT(message: String, inviteeAccount: Account, publicKey: DIDKey) throws -> String {
        guard let identityKey = identityStorage.getIdentityKey(for: accountService.currentAccount)
        else { throw Errors.identityKeyNotFound }
        return try JWTFactory(keyPair: identityKey).createChatInviteProposalJWT(
            ksu: keyserverURL.absoluteString,
            aud: inviteeAccount.did,
            sub: message,
            pke: publicKey.did(prefix: true, variant: .X25519)
        )
    }
}

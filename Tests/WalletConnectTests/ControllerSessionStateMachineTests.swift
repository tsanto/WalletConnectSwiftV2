import XCTest
import WalletConnectUtils
@testable import TestingUtils
import WalletConnectKMS
@testable import WalletConnect


class ControllerSessionStateMachineTests: XCTestCase {
    var sut: ControllerSessionStateMachine!
    var relayMock: MockedWCRelay!
    var storageMock: SessionSequenceStorageMock!
    var cryptoMock: KeyManagementServiceMock!
    
    override func setUp() {
        relayMock = MockedWCRelay()
        storageMock = SessionSequenceStorageMock()
        cryptoMock = KeyManagementServiceMock()
        sut = ControllerSessionStateMachine(relay: relayMock, kms: cryptoMock, sequencesStore: storageMock, logger: ConsoleLoggerMock())
    }
    
    override func tearDown() {
        relayMock = nil
        storageMock = nil
        cryptoMock = nil
        sut = nil
    }
    
    // MARK: - Update Methods
        
    func testUpdateMethodsSuccess() throws {
        let session = SessionSequence.stub(isSelfController: true)
        storageMock.setSequence(session)
        let methodsToUpdate: Set<String> = ["m1", "m2"]
        try sut.updateMethods(topic: session.topic, methods: methodsToUpdate)
        let updatedSession = storageMock.getSequence(forTopic: session.topic)
        XCTAssertTrue(relayMock.didCallRequest)
        XCTAssertEqual(methodsToUpdate, updatedSession?.methods)
    }
    
    func testUpdateMethodsErrorSessionNotFound() {
        XCTAssertThrowsError(try sut.updateMethods(topic: "", methods: ["m1"])) { error in
            XCTAssertTrue(error.isNoSessionMatchingTopicError)
        }
    }
    
    func testUpdateMethodsErrorSessionNotAcknowledged() {
        let session = SessionSequence.stub(acknowledged: false)
        storageMock.setSequence(session)
        XCTAssertThrowsError(try sut.updateMethods(topic: session.topic, methods: ["m1"])) { error in
            XCTAssertTrue(error.isSessionNotAcknowledgedError)
        }
    }

    func testUpdateMethodsErrorInvalidMethod() {
        let session = SessionSequence.stub(isSelfController: true)
        storageMock.setSequence(session)
        XCTAssertThrowsError(try sut.updateMethods(topic: session.topic, methods: [""])) { error in
            XCTAssertTrue(error.isInvalidMetodError)
        }
    }

    func testUpdateMethodsErrorCalledByNonController() {
        let session = SessionSequence.stub(isSelfController: false)
        storageMock.setSequence(session)
        XCTAssertThrowsError(try sut.updateMethods(topic: session.topic, methods: ["m1"])) { error in
            XCTAssertTrue(error.isUnauthorizedNonControllerCallError)
        }
    }
}
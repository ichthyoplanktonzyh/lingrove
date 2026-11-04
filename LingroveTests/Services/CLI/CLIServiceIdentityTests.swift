import Foundation
import Testing
@testable import Lingrove

/// These checks protect the transport boundary independently of notebook validation: an old
/// client or a delayed request for another lease must never reach the archive's write handler.
struct CLIServiceIdentityTests {
    @Test func requiresCurrentProtocolPathAndLease() throws {
        let identity = CLIServiceIdentity(appURL: URL(fileURLWithPath: "/Synthetic.app"))
        var request = CLIRequest(command: .apply)
        #expect(throws: CLIError.self) { try identity.validate(request) }
        request.serverInstanceID = identity.instanceID
        request.targetAppPath = identity.appPath
        try identity.validate(request)
        request.serverInstanceID = UUID()
        #expect(throws: CLIError.self) { try identity.validate(request) }
        request.serverInstanceID = identity.instanceID
        request.targetAppPath = "/Other.app"
        #expect(throws: CLIError.self) { try identity.validate(request) }
        request.targetAppPath = identity.appPath
        request.version = 1
        #expect(throws: CLIError.self) { try identity.validate(request) }
        try identity.validate(CLIRequest(command: .hello))
    }
}

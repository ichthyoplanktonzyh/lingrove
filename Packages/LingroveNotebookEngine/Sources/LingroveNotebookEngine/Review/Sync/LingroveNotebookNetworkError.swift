import Foundation
public nonisolated enum LingroveNotebookNetworkError: Error, Equatable {
    case invalidEndpoint, invalidReply, replyTooLarge, identityMismatch
    case stagedUnavailable
    case http(status: Int, code: String?)
}

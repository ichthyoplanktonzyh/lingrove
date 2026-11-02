import Foundation

/// Read-only native metadata transport. Login may list actual authorized workspaces; settings are
/// fetched only for the user's chosen workspace. The existing bootstrap protocol sorts scheduler
/// settings first, so a one-entry pull receives no generic Card, Deck or media payload.
@MainActor
public final class AccountWorkspaceClient: AccountWorkspaceLoading {
    private let http: BoundedHTTPClient
    public init(session: URLSession? = nil) { http = .init(session: session) }

    public func metadata(authorization: AccountAuthorization) async throws -> AccountWorkspaceMetadata {
        let me: WorkspaceMe = try await request(path: "/me", authorization: authorization)
        guard me.userId.utf8.elementsEqual(authorization.identity.userID.utf8) else {
            throw AccountWorkspaceError.identityChanged
        }
        var workspaces: [AccountWorkspace] = [], cursor: String?, seenCursors = Set<String>()
        for _ in 0..<32 {
            var path = "/workspaces?limit=100"
            if let cursor {
                var query = URLComponents(); query.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
                guard let encoded = query.percentEncodedQuery else { throw AccountWorkspaceError.invalidResponse }
                path += "&" + encoded
            }
            let page: WorkspacePage = try await request(path: path, authorization: authorization)
            guard page.workspaces.count <= 100 else { throw AccountWorkspaceError.invalidResponse }
            for workspace in page.workspaces {
                guard UUID(uuidString: workspace.workspaceId)?.uuidString.lowercased() == workspace.workspaceId,
                      !workspace.name.isEmpty, workspace.name.utf8.count <= 1_024,
                      validDate(workspace.createdAt), !workspaces.contains(where: { $0.id == workspace.id }) else {
                    throw AccountWorkspaceError.invalidResponse
                }
                workspaces.append(workspace)
            }
            guard let next = page.nextCursor else {
                return .init(identity: authorization.identity, selectedWorkspaceID: me.selectedWorkspaceId,
                    workspaces: workspaces.filter(\.isVisible))
            }
            guard !next.isEmpty, next.utf8.count <= 8_192, seenCursors.insert(next).inserted else {
                throw AccountWorkspaceError.invalidResponse
            }
            cursor = next
        }
        throw AccountWorkspaceError.invalidResponse
    }

    public func schedulerSettings(workspaceID: UUID, installationID: UUID,
                                  authorization: AccountAuthorization) async throws -> AccountWorkspaceSchedulerSettings {
        let fields: [String: Any] = ["mode": "pull", "installationId": installationID.uuidString.lowercased(),
            "platform": "macos", "osName": "macos", "deviceType": "desktop", "appVersion": "1",
            "isAutomation": false, "isTestDistribution": false, "cursor": NSNull(), "limit": 1,
            "includeMediaAssets": false]
        let page: SchedulerPage = try await request(path: "/workspaces/\(workspaceID.uuidString.lowercased())/sync/bootstrap",
            authorization: authorization, body: JSONSerialization.data(withJSONObject: fields))
        guard page.entries.count == 1, let entry = page.entries.first,
              entry.entityType == "workspace_scheduler_settings", entry.entityId == workspaceID.uuidString.lowercased(),
              entry.action == "upsert" else { throw AccountWorkspaceError.invalidResponse }
        let settings = entry.payload
        guard settings.algorithm == "fsrs-6", settings.desiredRetention.isFinite,
              settings.desiredRetention > 0, settings.desiredRetention < 1,
              validSteps(settings.learningStepsMinutes), validSteps(settings.relearningStepsMinutes),
              settings.maximumIntervalDays > 0,
              validDate(settings.clientUpdatedAt), validDate(settings.updatedAt),
              validIdentifier(settings.lastModifiedByReplicaId), validIdentifier(settings.lastOperationId) else {
            throw AccountWorkspaceError.invalidResponse
        }
        return settings
    }

    private func request<Value: Decodable>(
        path: String, authorization: AccountAuthorization, body: Data? = nil
    ) async throws -> Value {
        try Task.checkCancellation()
        let base = try AccountConfigurationPolicy.baseURL(authorization.configuration.apiBaseURL.absoluteString)
        guard let url = URL(string: base.absoluteString + path) else { throw AccountIssue.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("Bearer \(authorization.idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await http.response(for: request, maximumBytes: 256 * 1024,
                errorMaximumBytes: 8_192, acceptedStatusCodes: 200..<201)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if error is URLError { throw AccountWorkspaceError.network }
            throw AccountWorkspaceError.invalidResponse
        }
        try validateHTTPStatus(response.statusCode)
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else { throw AccountWorkspaceError.invalidResponse }
        return value
    }

    private func validateHTTPStatus(_ code: Int) throws {
        switch code {
        case 200: break
        case 401, 410: throw AccountWorkspaceError.authentication
        case 403: throw AccountWorkspaceError.forbidden
        case 404, 501, 503: throw AccountWorkspaceError.unavailable
        default: throw AccountWorkspaceError.invalidResponse
        }
    }

    // The existing backend contract allows every positive integer step/interval. The bounded
    // response budget limits allocation; arbitrary UI-style caps would reject valid phone settings.
    private func validSteps(_ values: [Int]) -> Bool { !values.isEmpty && values.allSatisfy { $0 > 0 } }
    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.contains(where: \.isWhitespace)
    }
    private func validDate(_ value: String) -> Bool {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) != nil || ISO8601DateFormatter().date(from: value) != nil
    }
}

// These private per-request DTOs retain only identity/list/scheduler fields from the fixed wire
// envelopes. Extra profile/Card fields have no route into native state or notebook storage.
private struct WorkspaceMe: Decodable { let userId: String; let selectedWorkspaceId: String? }
private struct WorkspacePage: Decodable { let workspaces: [AccountWorkspace]; let nextCursor: String? }
private struct SchedulerPage: Decodable {
    struct Entry: Decodable {
        let entityType: String; let entityId: String; let action: String
        let payload: AccountWorkspaceSchedulerSettings
    }
    let entries: [Entry]
}

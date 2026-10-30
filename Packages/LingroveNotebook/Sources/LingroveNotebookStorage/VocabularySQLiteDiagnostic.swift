/// A synchronous storage call can report a failure without depending on the
/// host's logger. The owning archive supplies routing; these values contain no
/// C pointer, SQL bindings or user text and never suspend the locked operation.
public nonisolated enum VocabularySQLiteDiagnostic: Sendable {
    case connectionFailed(code: Int32)
    case operationFailed(code: Int32)
}

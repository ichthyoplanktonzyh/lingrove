/// The Mac host records why a service pair was selected. This is presentation metadata, not
/// request authority: the shared session still uses only its validated, saved configuration.
/// Keeping the source with that pair prevents a custom server from being relabeled as Lingrove.
nonisolated enum AccountConnectionSource: String, Codable {
    case applicationDefault
    case custom
}

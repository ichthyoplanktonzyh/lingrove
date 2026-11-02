import CryptoKit
import Foundation

/// Deterministic workspace replica identity retained from the mobile upload contract.
public func mediaUploadWorkspaceReplicaId(workspaceId: String, installationId: String) -> String {
    let seed = "\(workspaceId):\(installationId)"
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    )).uuidString.lowercased()
}

import Foundation

public struct ReviewQuerySQL {
    public let clause: String
    public let values: [SQLiteValue]

    public init(clause: String, values: [SQLiteValue]) {
        self.clause = clause
        self.values = values
    }
}

public struct CardStore {
    public let core: DatabaseCore

    public init(core: DatabaseCore) {
        self.core = core
    }
}

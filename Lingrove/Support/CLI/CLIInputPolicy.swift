import Foundation

/// Shared input validation fails on misspelled keys instead of silently dropping an agent's
/// intended note or example. The published schema and domain validation serve different roles:
/// this file checks wire shape; VocabularyCLIPlan checks notebook semantics.
nonisolated enum CLIInputPolicy {
    static let maximumBytes = 32 * 1_024 * 1_024
    static func decode(_ data: Data) throws -> CLIBatch {
        guard data.count <= maximumBytes else { throw CLIError.invalid("Input exceeds 32 MiB.") }
        do {
            try validateShape(JSONSerialization.jsonObject(with: data))
            let batch = try JSONDecoder().decode(CLIBatch.self, from: data)
            try validate(batch)
            return batch
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.invalid("Invalid batch JSON; run 'lingrove schema' for the input format.")
        }
    }

    /// Validate the untyped envelope before Codable can silently ignore an unknown field. These
    /// helpers share no state; each owns one nesting level and retains its original error path.
    private static func validateShape(_ value: Any) throws {
        let root = try object(value, keys: ["version", "idempotencyKey", "operations"], at: "batch")
        guard let operations = root["operations"] as? [Any], !operations.isEmpty, operations.count <= 100 else {
            throw CLIError.invalid("Provide 1–100 operations.")
        }
        for (index, operation) in operations.enumerated() {
            try validateOperationShape(operation, path: "operations[\(index)]")
        }
    }

    private static func object(_ value: Any, keys: Set<String>, at path: String) throws -> [String: Any] {
        guard let value = value as? [String: Any], Set(value.keys).isSubset(of: keys) else {
            throw CLIError.invalid("Unknown fields or invalid object at " + path + ".")
        }
        return value
    }

    private static func validateOperationShape(_ value: Any, path: String) throws {
        let operation = try object(value, keys: ["add", "append", "update"], at: path)
        guard operation.count == 1, let kind = operation.keys.first, let payload = operation[kind] else {
            throw CLIError.invalid("Each operation needs exactly one action.")
        }
        let keys: Set<String> = switch kind {
        case "add":
            ["expression", "dictionaryForm", "language", "kind", "meaning", "meaningLanguage", "note", "tags", "examples", "content"]
        case "append":
            ["entryID", "senseID", "examples", "content", "tags"]
        default:
            ["entryID", "senseID", "expectedRevision", "meaning", "meaningLanguage", "note", "tags"]
        }
        let fields = try object(payload, keys: keys, at: path)
        if let blocks = fields["content"] { try validateContentShape(blocks, path: path + ".content") }
        if let examples = fields["examples"] { try validateExampleShape(examples, path: path + ".examples") }
    }

    private static func validateContentShape(_ value: Any, path: String) throws {
        guard let blocks = value as? [Any], blocks.count <= 64 else {
            throw CLIError.invalid("Expected at most 64 content blocks at " + path + ".")
        }
        for block in blocks {
            let fields = try object(block, keys: ["text", "image", "bold", "italic"], at: path)
            if let image = fields["image"] {
                _ = try object(image, keys: ["path", "caption"], at: path + ".image")
            }
        }
    }

    private static func validateExampleShape(_ value: Any, path: String) throws {
        guard let examples = value as? [Any], examples.count <= 100 else {
            throw CLIError.invalid("Expected at most 100 examples at " + path + ".")
        }
        for example in examples {
            let fields = try object(example, keys: [
                "text", "translation", "translationLanguage", "meaning", "meaningLanguage", "completeness", "ranges"
            ], at: path)
            if let ranges = fields["ranges"] { try validateRangeShape(ranges, path: path + ".ranges") }
        }
    }

    private static func validateRangeShape(_ value: Any, path: String) throws {
        guard let ranges = value as? [Any], ranges.count <= 64 else {
            throw CLIError.invalid("Expected at most 64 ranges.")
        }
        for range in ranges { _ = try object(range, keys: ["location", "length"], at: path) }
    }

    /// Runs before either process reads/decodes images. Byte limits alone do not bound how many
    /// empty or tiny file paths an otherwise small JSON document could ask us to open.
    static func validate(_ batch: CLIBatch) throws {
        guard batch.version == 1, (1...200).contains(batch.idempotencyKey.utf8.count),
              !batch.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...100).contains(batch.operations.count) else {
            throw CLIError.invalid("Invalid batch header or operation count.")
        }
        var images = 0, blocks = 0, examples = 0, imageBytes = 0
        for operation in batch.operations {
            guard [operation.add != nil, operation.append != nil, operation.update != nil].filter({ $0 }).count == 1 else {
                throw CLIError.invalid("Each operation needs exactly one action.")
            }
            let content = operation.add?.content ?? operation.append?.content ?? []
            let usages = operation.add?.examples ?? operation.append?.examples ?? []
            guard content.count <= 64, usages.count <= 100 else {
                throw CLIError.invalid("Operation content count exceeds its limit.")
            }
            guard usages.allSatisfy({ ($0.ranges?.count ?? 0) <= 64 }) else {
                throw CLIError.invalid("At most 64 ranges are allowed per example.")
            }
            for block in content {
                guard (block.text != nil) != (block.image != nil) else { throw CLIError.invalid("Each block needs text or an image.") }
                if let image = block.image {
                    guard (image.path != nil) != (image.data != nil), block.bold == nil, block.italic == nil else {
                        throw CLIError.invalid("Invalid image block.")
                    }
                    imageBytes += image.data?.count ?? 0
                }
            }
            images += content.filter { $0.image != nil }.count; blocks += content.count; examples += usages.count
        }
        guard images <= 64, blocks <= 512, examples <= 1_000, imageBytes <= 16 * 1_024 * 1_024 else {
            throw CLIError.invalid("Batch exceeds 64 images, 16 MiB image bytes, 512 blocks or 1000 examples.")
        }
    }
}

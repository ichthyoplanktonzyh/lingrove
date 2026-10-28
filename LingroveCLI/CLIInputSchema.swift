import Foundation

/// The CLI publishes its input contract without launching the app. Paths and UUIDs belong to
/// the caller; semantic language support, UTF-8 byte limits and ownership are checked by the app.
enum CLIInputSchema {
    /// Resource definitions come from the validator compiled into both processes. The static
    /// traditional definitions below remain part of the same discoverable batch contract.
    static var json: String {
        do {
            var root = try JSONSerialization.jsonObject(with: Data(legacy.utf8)) as? [String: Any] ?? [:]
            root["title"] = "Lingrove vocabulary and resource batch"
            var properties = root["properties"] as? [String: Any] ?? [:]
            properties["version"] = ["enum": [1, 2]]
            properties["expectedRevision"] = ["type": "integer", "minimum": 0]
            var operations = properties["operations"] as? [String: Any] ?? [:]
            var items = operations["items"] as? [String: Any] ?? [:]
            var alternatives = items["oneOf"] as? [[String: Any]] ?? []
            alternatives.append(["type": "object", "additionalProperties": false, "required": ["capture"],
                "properties": ["capture": CLICaptureContract.shape.schema]])
            alternatives += try CLIResourceContract.names.map { name in
                var shape = try CLIResourceContract.shape(name).schema
                shape["x-requiredOnCreate"] = shape["required"]
                shape["required"] = [name == "collections" ? "senseID" : "id"]
                return ["type": "object", "additionalProperties": false, "required": ["put"], "properties": [
                    "put": ["type": "object", "additionalProperties": false, "required": ["resource", "value"],
                            "properties": ["resource": ["const": name], "value": shape]]]]
            }
            alternatives.append(["type": "object", "additionalProperties": false, "required": ["delete"], "properties": [
                "delete": ["type": "object", "additionalProperties": false, "required": ["resource", "id"],
                           "properties": ["resource": ["enum": CLIResourceContract.names], "id": ["type": "string", "format": "uuid"]]]]])
            items["oneOf"] = alternatives; operations["items"] = items; properties["operations"] = operations
            root["properties"] = properties
            root["allOf"] = [["if": ["properties": ["operations": ["contains": ["anyOf": [
                ["required": ["put"]], ["required": ["delete"]]]]]]],
                "then": ["required": ["expectedRevision"], "properties": ["version": ["const": 2]]]]]
            var rules = root["allOf"] as? [[String: Any]] ?? []
            rules.append(["if": ["properties": ["operations": ["contains": ["required": ["capture"]]]]],
                "then": ["properties": ["version": ["const": 2]]]])
            root["allOf"] = rules
            var definitions = root["$defs"] as? [String: Any] ?? [:]
            var example = definitions["example"] as? [String: Any] ?? [:]
            var fields = example["properties"] as? [String: Any] ?? [:]
            fields["completeness"] = ["enum": ["sentence", "fragment", "unknown"]]
            fields["sourceKind"] = ["enum": ["unspecified", "captured", "authored", "generated", "imported"]]
            example["properties"] = fields; definitions["example"] = example; root["$defs"] = definitions
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            guard let json = String(data: data, encoding: .utf8) else {
                preconditionFailure("JSONSerialization must produce UTF-8 schema data.")
            }
            return json
        } catch { preconditionFailure("The built-in CLI schema must be valid JSON: \(error)") }
    }

    private static let legacy = #"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Lingrove vocabulary batch v1",
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "version": {
      "const": 1
    },
    "idempotencyKey": {
      "type": "string",
      "minLength": 1,
      "maxLength": 200
    },
    "operations": {
      "type": "array",
      "minItems": 1,
      "maxItems": 100,
      "items": {
        "oneOf": [
          {
            "type": "object",
            "additionalProperties": false,
            "properties": {
              "add": {
                "$ref": "#/$defs/add"
              }
            },
            "required": [
              "add"
            ]
          },
          {
            "type": "object",
            "additionalProperties": false,
            "properties": {
              "append": {
                "$ref": "#/$defs/append"
              }
            },
            "required": [
              "append"
            ]
          },
          {
            "type": "object",
            "additionalProperties": false,
            "properties": {
              "update": {
                "$ref": "#/$defs/update"
              }
            },
            "required": [
              "update"
            ]
          }
        ]
      }
    }
  },
  "required": [
    "version",
    "idempotencyKey",
    "operations"
  ],
  "$defs": {
    "range": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "location": {
          "type": "integer",
          "minimum": 0
        },
        "length": {
          "type": "integer",
          "minimum": 1
        }
      },
      "required": [
        "location",
        "length"
      ]
    },
    "example": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "text": {
          "type": "string",
          "minLength": 1
        },
        "translation": {
          "type": "string"
        },
        "translationLanguage": {
          "type": "string"
        },
        "meaning": {
          "type": "string"
        },
        "meaningLanguage": {
          "type": "string"
        },
        "completeness": {
          "enum": [
            "sentence",
            "fragment"
          ]
        },
        "ranges": {
          "type": "array",
          "maxItems": 64,
          "items": {
            "$ref": "#/$defs/range"
          }
        }
      },
      "required": [
        "text"
      ]
    },
    "block": {
      "oneOf": [
        {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "text": {
              "type": "string",
              "minLength": 1
            },
            "bold": {
              "type": "boolean"
            },
            "italic": {
              "type": "boolean"
            }
          },
          "required": [
            "text"
          ]
        },
        {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "image": {
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "path": {
                  "type": "string",
                  "minLength": 1
                },
                "caption": {
                  "type": "string"
                }
              },
              "required": [
                "path"
              ]
            }
          },
          "required": [
            "image"
          ]
        }
      ]
    },
    "add": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "expression": {
          "type": "string",
          "minLength": 1
        },
        "dictionaryForm": {
          "type": "string",
          "minLength": 1
        },
        "language": {
          "type": "string",
          "minLength": 1
        },
        "kind": {
          "enum": [
            "word",
            "expression",
            "pattern",
            "sentence"
          ]
        },
        "meaning": {
          "type": "string",
          "minLength": 1
        },
        "meaningLanguage": {
          "type": "string"
        },
        "note": {
          "type": "string"
        },
        "tags": {
          "type": "array",
          "maxItems": 100,
          "items": {
            "type": "string",
            "minLength": 1,
            "maxLength": 200
          }
        },
        "examples": {
          "type": "array",
          "maxItems": 100,
          "items": {
            "$ref": "#/$defs/example"
          }
        },
        "content": {
          "type": "array",
          "maxItems": 64,
          "items": {
            "$ref": "#/$defs/block"
          }
        }
      },
      "required": [
        "expression",
        "language",
        "kind",
        "meaning"
      ]
    },
    "append": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "entryID": {
          "type": "string",
          "format": "uuid"
        },
        "senseID": {
          "type": "string",
          "format": "uuid"
        },
        "tags": {
          "type": "array",
          "maxItems": 100,
          "items": {
            "type": "string",
            "minLength": 1,
            "maxLength": 200
          }
        },
        "examples": {
          "type": "array",
          "maxItems": 100,
          "items": {
            "$ref": "#/$defs/example"
          }
        },
        "content": {
          "type": "array",
          "maxItems": 64,
          "items": {
            "$ref": "#/$defs/block"
          }
        }
      },
      "required": [
        "entryID",
        "senseID"
      ]
    },
    "update": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "entryID": {
          "type": "string",
          "format": "uuid"
        },
        "senseID": {
          "type": "string",
          "format": "uuid"
        },
        "expectedRevision": {
          "type": "integer",
          "minimum": 0
        },
        "meaning": {
          "type": "string",
          "minLength": 1
        },
        "meaningLanguage": {
          "type": "string"
        },
        "note": {
          "type": "string"
        },
        "tags": {
          "type": "array",
          "maxItems": 100,
          "items": {
            "type": "string",
            "minLength": 1,
            "maxLength": 200
          }
        }
      },
      "required": [
        "entryID",
        "senseID",
        "expectedRevision"
      ],
      "anyOf": [
        {
          "required": [
            "meaning"
          ]
        },
        {
          "required": [
            "meaningLanguage"
          ]
        },
        {
          "required": [
            "note"
          ]
        },
        {
          "required": [
            "tags"
          ]
        }
      ]
    }
  }
}
"""#
}

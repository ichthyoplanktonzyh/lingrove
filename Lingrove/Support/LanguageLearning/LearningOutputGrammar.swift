import Foundation

/// Fixed output contracts for local learning requests. The explanation service chooses one
/// grammar per generation; the runtime borrows its text only while creating that sequence.
/// Keeping these rules separate from prompts lets llama.cpp enforce JSON escaping without
/// treating a valid structure as evidence that a model's definition is correct.
nonisolated enum LearningOutputGrammar {
    static let explanation = object(secondField: "explanation", secondValue: "string")

    static func lookup(hasContext: Bool) -> String {
        object(secondField: "sentence_translation", secondValue: hasContext ? "string" : "empty")
    }

    private static func object(secondField: String, secondValue: String) -> String {
        // Field names and rule names are trusted constants, never captured text. Byte/display
        // limits remain in the parsers: large bounded repetitions would inflate the grammar.
        #"""
        root ::= "{" ws "\"meaning\"" ws ":" ws string ws "," ws "\"\#(secondField)\"" ws ":" ws \#(secondValue) ws "}" ws
        string ::= "\"" char+ "\""
        empty ::= "\"\""
        char ::= [^"\\\x00-\x1F\x7F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4})
        ws ::= [ \t\n\r]{0,16}
        """#
    }
}

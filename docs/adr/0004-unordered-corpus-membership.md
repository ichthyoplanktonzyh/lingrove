# Corpus members have identity, not ordinal meaning

Senses of an expression and independent examples of a sense are unordered memberships. Changing
their array positions changes neither corpus content nor learning history. Corpus entities,
semantic assertions and classification memberships use stable identity; authored paragraphs,
images, source text/spans, explanation history and template structure retain their sequence.

We chose membership semantics over sparse/fractional ordering keys because user-defined ordinal
meaning is not part of these collections. Arrays remain transport and presentation containers.
Domain equality compares members by identity without silently deduplicating invalid input.
Default presentation/selection uses creation time and identity; saved review material continues
to reference explicit sense/example IDs. SQLite ignores legacy positions for membership rows
and writes zero for new rows, so deleting one member does not journal surviving members. Existing
payloads and IDs are read without a destructive migration; consumers must share this codec's
membership semantics. Ordered body/history/template rows retain strict position checks.

The existing wire envelope still carries rank. Unordered members ignore its meaning, new members
use zero, and uploads retain confirmed ranks rather than patching every existing row on upgrade.
Set-valued additions still obey the existing add/reset clocks; removing a member cannot be undone
by an arbitrary union during rebase. This changes client modeling, not permissions, server version
checks, account isolation or transmission scope. Transport byte windows remain ordered and hashed.

# Lingrove namespace migration

First-party source and tests now live in `Lingrove/` and `LingroveTests/`. Open
`Lingrove.xcodeproj`, or prepare `build/lingrove-dependencies/Lingrove.xcworkspace` with
`scripts/prepare_lingrove_workspace.sh`. Both app targets and shared schemes use Lingrove names.
The Swift app module is `Lingrove`; the command `lingrove` uses the distinct `LingroveCLI` module
because module artifact paths on the usual macOS filesystem are case-insensitive.

## Existing installations

Production and Dev keep their existing Lingrove Bundle IDs, signing identities, application-support
folders, Keychain services, model filenames, encrypted history and vocabulary database. Source-code
renaming does not import data from a separately installed upstream Cotabby application.

Before the app graph creates settings or views, `LingrovePreferencesMigration` reads only its own
persistent preference domain. It copies `cotabby…` keys to `lingrove…`, including the old settings
window frame. Already-present new keys win. Original keys remain for recovery, and a version marker
prevents a later reset from resurrecting an old value. A private, atomic plist snapshot is saved
under the app's `MigrationBackups` directory before copying existing settings. XCTest hosts skip
this application startup and test the migration using independent temporary domains.

Command-line preference overrides stay in the volatile argument domain; they are never saved by
this migration. Old `-cotabby…` flags and `COTABBY_…` environment variables remain accepted, while
new flags/environment names take precedence where both are supplied. Newly generated scripts and
relaunch commands use `-lingrove…` and `LINGROVE_…`.
After the one-time upgrade, direct `defaults write` commands must use the new `lingrove…`
preference keys. Retained legacy keys are recovery data, not a bidirectional settings bridge.

## Diagnostics

The Console subsystem is `io.ichthyoplanktonzyh.lingrove`. Category parsing supports both the new
namespace and historical `com.cotabby` labels. The current event file is `lingrove.jsonl` under the
existing per-app log directory. The first open moves an old event file without rewriting its
contents, and creates a legacy filename alias when possible. Existing histories are never
replaced when both filenames already exist. New Chrome AX dumps use `lingrove-ax-dump.txt`;
older Desktop dumps are left alone because that global location may also belong to the upstream app.

## Names deliberately retained

`CotabbyInference` is the actual upstream package/module and API name, and its pending patch keeps
that name. Original authorship, license texts, upstream localization keys, historical benchmark
records and quoted study material retain their provenance. These are not first-party identifiers.

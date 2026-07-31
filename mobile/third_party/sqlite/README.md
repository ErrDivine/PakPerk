# Vendored SQLite amalgamation

Pakperk compiles `sqlite3.c` from this directory through the `package:sqlite3`
native-assets hook. Vendoring the upstream amalgamation makes Android and iOS
release builds reproducible and removes a build-time dependency on downloading
precompiled binaries from GitHub.

- Upstream: <https://www.sqlite.org/download.html>
- Version: SQLite 3.53.3 (2026-06-26)
- Archive: `sqlite-amalgamation-3530300.zip`
- Archive SHA3-256: `d45c688a8cb23f68611a894a756a12d7eb6ab6e9e2468ca70adbeab3808b5ab9`
- `sqlite3.c` SHA3-256: `28e484abdaa43630e34040ef6ed92be973a1ad54107803d8af5145b889c23ed7`

SQLite's upstream source is dedicated to the public domain. The compile-time
feature defines remain owned by the pinned `sqlite3` Dart package, so source
and binary builds use the same Drift-required feature set.

When updating, download the official amalgamation, verify both hashes against
SQLite's release pages, replace only `sqlite3.c`, update this record, and run
the full unit and native build gates.

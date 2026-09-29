# ByteNet (vendored, unmodified)

| | |
|---|---|
| Repo | https://github.com/ffrostfall/ByteNet (formerly ffrostflame/ByteNet) |
| Version | 0.4.6 (Wally `ffrostflame/bytenet@0.4.6`, the latest published release) |
| Commit | `92addc1` (2024-07-10, "Changelog"), the last commit of the 0.4.x line |
| License | MIT, "Copyright 2023 ffrostfall" (`LICENSE`, from the same commit) |
| Fetched | 2026-09-28: `git clone`, then `git archive 92addc1 src LICENSE` |

`master` (`fbdb156`) is an unfinished 0.5.0 rewrite that does not run (it requires modules that do not exist and calls undefined globals), so the last release is vendored. The Wally 0.4.6 package was checked byte-for-byte against `src/` at `92addc1`.

## Files

Everything in `src/` at `92addc1` (35 `.luau` files), minus `index.d.ts` (roblox-ts typings), `dataTypes/README.md` and `dataTypes/color3.luau` (never required in 0.4.6). No edits, no dependencies.

This folder is the package: `init.luau` becomes the ModuleScript `ReplicatedStorage.Bench.Libs.ByteNet`. On require it creates `ReplicatedStorage.ByteNetReliable`, `ByteNetUnreliable` and `BytenetStorage`.

Third-party code: never reformatted and excluded from the bench's strict luau-lsp and stylua checks.

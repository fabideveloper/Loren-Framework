# BridgeNet2 (vendored)

| | |
|---|---|
| Repo | https://github.com/ffrostfall/BridgeNet2 (formerly ffrostflame/BridgeNet2) |
| Version | 1.0.0 (git tag `v1.0.0` = GitHub release v1.0.0 = Wally `ffrostflame/bridgenet2@1.0.0`) |
| Commit | `69f8fc3` (2023-10-20). `src/` is identical at `381ead0`, the last commit before the rewrite |
| License | MIT, "Copyright 2023 ffrostfall" (`LICENSE`, from `69f8fc3`) |
| Fetched | 2026-09-28: `git clone`, then `git archive 69f8fc3 src` |

`master` (`d7fd18a`) is an unfinished "2.0.0-rc1" rewrite, so the last release is vendored.

## Layout (the same as upstream's `release.js` standalone build)

| Path | Source |
|---|---|
| `init.luau` | new, one line: `return require(script.src)` |
| `src/` | upstream `src/` at `69f8fc3`, unmodified, minus the empty `src/Studio/MockIdentifiers.luau` |
| `TableKit.luau` | `ffrostflame/tablekit@0.2.4` `src/init.luau`, unmodified, from the Wally archive (MIT, `LICENSE-TableKit`). GitHub `master` is not 0.2.4 |
| `RemotePacketSizeCounter.luau` | `pysephwasntavailable/remotepacketsizecounter@2.1.0` `src/init.luau`, unmodified (MIT, `LICENSE-RemotePacketSizeCounter`); same file as `Pyseph/RemotePacketSizeCounter@511a029` |
| `wallyInstanceManager.luau` | new code (a shim). `ffrostflame/wally-instance-manager@0.1.0` has no license, so it is not copied; the shim provides the same `add`/`get`/`waitForInstance` calls |

The package maps to `ReplicatedStorage.Bench.Libs.BridgeNet2`. The shim parents its remotes to a folder named after the package, `ReplicatedStorage.BridgeNet2`, so the package itself must not sit directly in ReplicatedStorage. Require it at server start: players who joined before the first require never get `AllPlayers` broadcasts.

Third-party code: never reformatted and excluded from the bench's strict luau-lsp and stylua checks.

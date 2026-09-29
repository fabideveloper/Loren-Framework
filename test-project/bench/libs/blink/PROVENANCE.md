# Blink (generated, unmodified)

| | |
|---|---|
| Repo | https://github.com/1Axen/blink |
| Version | v0.18.9, tag commit `86b04ef50101fea622f7b701eaf936924040e5cd` |
| License | MIT, "Copyright (c) 2024 Axen", copied verbatim to `LICENSE` |
| Compiler | official release asset `blink-windows-x86_64.tar.gz` (https://github.com/1Axen/blink/releases/download/v0.18.9/blink-windows-x86_64.tar.gz) |
| sha256 (tar.gz) | `db5e31ed9578c4bba37592765f5da2eb26f490770ff3021206e014ca8028b487` |
| sha256 (blink.exe) | `56076a3a2bba66bb125de7e3f03db25df6cd92712690b407828872415debd6d8` (`--version` prints "Blink 0.18.9") |
| Generated | 2026-09-28 |

## Exact command

The compiler ran only inside the session scratch folder (`scratchpad\signal`), with the working directory holding `Bench.blink`:

```
..\..\bin\blink\blink.exe Bench.blink
```

The schema is `Bench.blink` in this folder. It has the same events and payload types as `../blinkblox/Bench.blink`, minus the options Blink lacks (inbound limits, `Rate`, `BatchUnreliable`, `CFrame<quat>`).

## Files

| File | sha256 |
|---|---|
| `Server.luau` | `1ae5c2b7fe639ab9f92609e0c6323b5d57a0fae92be3daa838bf5d062a62ccc1` |
| `Client.luau` | `9afc71a30ecd3cb86a09490b6862fc0499121193434eab6f525840be501ea2a7` |
| `Bench.blink` | `cffc2b8f4caff421de95981ec6f0c5d81ca668b8ab4bba272a3d3f3c60922bdc` |

The modules are self-contained (no `require`). `Server.luau` maps to `ServerStorage.Bench.BlinkServer`, `Client.luau` to `ReplicatedStorage.Bench.Libs.BlinkClient`. They create `ReplicatedStorage.BLINK_BLINK_RELIABLE_REMOTE` and `BLINK_BLINK_UNRELIABLE_REMOTE`.

Third-party code: never reformatted and excluded from the bench's strict luau-lsp and stylua checks.

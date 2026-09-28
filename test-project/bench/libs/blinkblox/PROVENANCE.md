# BlinkBlox (generated, unmodified)

| | |
|---|---|
| Repo | https://github.com/XopoIII/BlinkBlox (a maintained fork of 1Axen/blink) |
| Version | v0.41.2, tag commit `0028d129aa1df9aa3029524cb0b16a9eedec475d` |
| License | MIT, "Copyright (c) 2024 Axen", copied verbatim to `LICENSE` |
| Compiler | official release asset `blinkblox-windows-x86_64.tar.gz` (https://github.com/XopoIII/BlinkBlox/releases/download/v0.41.2/blinkblox-windows-x86_64.tar.gz) |
| sha256 (tar.gz) | `c922d64104fe2aa6db0c83f1b0d861662e3ff75b5b9191dfe56d0bc37be570c6` |
| sha256 (blinkblox.exe) | `06dd19cee7a4d0617e8a90917de9aff9fe66cc970bc7159a7a88aa5fe5bfc9ad` (`--version` prints "BlinkBlox 0.41.2") |
| Generated | 2026-09-28 |

## Exact command

The compiler ran only inside the session scratch folder (`scratchpad\signal`), with the working directory holding `Bench.blink`:

```
..\..\bin\blinkblox\blinkblox.exe Bench.blink --yes
```

The schema is `Bench.blink` in this folder (its output options must be written `"./Client.luau"`; a bare name fails on Windows with "Access is denied").

## Files

| File | sha256 |
|---|---|
| `Server.luau` | `a1ffa005fc98ac9f6807e0ce6daba89af250ada5f7de93759c43bc72ee871d74` |
| `Client.luau` | `561922203934239d3dc9914b32d620afa50ee141497683ec241446402e716b9b` |
| `Bench.blink` | `bdfc27aae3746c87d6f37402c8dad36d650f3fae6b9578d6bac3287d09a1fb81` |

The modules are self-contained (no `require`). `Server.luau` maps to `ServerStorage.Bench.BlinkBloxServer`, `Client.luau` to `ReplicatedStorage.Bench.Libs.BlinkBloxClient`. They create `ReplicatedStorage.BLINKBLOX_BLINK_RELIABLE_REMOTE` (with the `SchemaSignature` attribute) and `BLINKBLOX_BLINK_UNRELIABLE_REMOTE`.

Options set in the schema: `RemoteScope = "BLINKBLOX"`, `BatchUnreliable = true`, raised inbound limits (as BlinkBlox's own benchmark does), and `Rate: 1000000` on every client event so the rate check is paid. Every event is `Call: SingleSync`.

Third-party code: never reformatted and excluded from the bench's strict luau-lsp and stylua checks.

# Loren CLI

Command-line tool for [Loren](https://fabideveloper.github.io/Loren-Framework/), a Roblox Luau framework.
It creates projects for **Rojo**, **Argon** or **Roblox Script Sync** (built into Studio), adds Services,
Controllers and packages, and updates a project's Loren runtime.

## Install

```bash
npm i -g loren-framework     # Node 18 or newer
```

You also need a toolchain manager ([Rokit](https://github.com/rojo-rbx/rokit) is recommended; Aftman and
Foreman work too) and the Rojo or Argon plugin in Studio (`rojo plugin install` / `argon plugin install`).

## Start a project

```bash
loren init my-game              # asks Rojo, Argon or None (Script Sync)
loren init my-game --tool argon --yes
cd my-game
loren serve                     # then connect the plugin in Studio and press Play
```

`init` writes the runtime (`loren/`), the bundled Promise, `src/` with a bootstrap, an example Service and an
example Controller, `rokit.toml`, `.gitignore` and `.vscode/settings.json`, then installs the toolchain and
builds the sourcemap. `--no-tools` skips those two steps (offline or CI).

## Commands

| Command | What it does |
| :--- | :--- |
| `loren init <name> [--tool rojo\|argon\|none] [--yes] [--no-tools]` | Create a project. |
| `loren make <service\|controller> <Name> [--force]` | Create `src/server/Services/<Name>.luau` or `src/client/Controllers/<Name>.luau` from the template. |
| `loren inject <service\|controller\|shared> <Name> [--force]` | Copy a premade into `Services/`, `Controllers/` or `src/shared/`. Your project's `loren_premade/` is searched first. |
| `loren inject --list` | List premades (built in: `PointsService`, `PointsController`, `ExampleShared`). |
| `loren add <user/repo[#ref] \| URL> [Alias] [--force]` | Download a repository into `loren_packages/<Alias>`. |
| `loren refresh [--watch]` | Regenerate `LorenTypes`, then the sourcemap. |
| `loren serve` (alias `ignite`) | Run `rojo serve` / `argon serve --sourcemap` (Script Sync: nothing to serve). |
| `loren migrate [--to rojo\|argon] [--yes]` | Switch the project between Rojo and Argon. |
| `loren update [--dry-run] [--yes] [--no-native]` | Update **this project's** runtime (see below). |
| `loren types` | Regenerate `LorenTypes.luau` and `LorenServerTypes.luau`. |
| `loren doctor [--fix] [--yes]` | Check Node, the toolchain, the project layout and your middleware. |

Every command that touches Rojo or Argon takes `--tool rojo|argon|none`; otherwise the tool comes from
`.loren.json` (Script Sync), then `rokit.toml` / `aftman.toml` / `foreman.toml`, then what is installed. Names must be Luau identifiers.
`make`, `inject` and `add` never overwrite anything without `--force` (the old copy goes to `.loren-backup/`).
Every command exits non-zero when a step fails, and never prompts without a terminal (pass `--yes`).

**Packages.** `loren add evaera/roblox-lua-promise` is refused: Promise is already bundled in
`loren_packages/Promise` and the runtime requires it. Try `loren add howmanysmall/Janitor` instead. A package
is a snapshot (no dependency resolution, no lockfile); pin a version with `#tag`. Require it with
`require(ReplicatedStorage.LorenPackages.<Alias>)`.

**Typed dependencies (optional).** `LorenTypes` (shared) and `LorenServerTypes` (server) list your module names.
The templates show the pattern: `Dependencies = { "Name" } :: { Types.ClientDependencyName }`, then
`local deps: Types.ClientDeps = self.Dependencies :: any`. `make`, `inject`, `add` and `refresh` keep them current.

## Updating

Two separate things get updated:

- **The CLI:** `npm i -g loren-framework`.
- **A project's runtime:** run `loren update` in the project root. It replaces `loren/`, writes the shim
  (`src/shared/Loren.luau`), patches `default.project.json`, vendors a test-free Promise, regenerates the types
  and the sourcemap, and runs the middleware lint. Replaced files are backed up to `.loren-backup/`. Your
  Services and Controllers are not touched, except for the optional middleware rewrite below.

**From 1.5.1:** your Services and Controllers run unchanged. `loren update --dry-run` shows the plan; `loren update`
applies it. If you wrote middleware in colon style (`function X.Middleware:Buy(player)`), `update` and
`doctor --fix` offer to rewrite it to dot style (`function X.Middleware.Buy(player)`); it needs a confirmation or
`--yes`. Then press Play in Studio and read Loren's boot report.

**Between 2.x versions:** update the CLI, then run `loren update` in each project. Running it twice is safe.

## Rojo or Argon

Both are fully supported. The differences Loren handles for you:

| | Rojo | Argon |
| :--- | :--- | :--- |
| `loren serve` | `rojo serve default.project.json` | `argon serve default.project.json --sourcemap` |
| Sourcemap | `rojo sourcemap ... -o sourcemap.json`; Luau-LSP regenerates it | `argon sourcemap ...`; Argon keeps it fresh while serving |
| `.vscode/settings.json` | `luau-lsp.sourcemap.autogenerate: true` | `false` (Argon writes it) |

`loren migrate` rewrites the toolchain manifest, the Luau-LSP settings and the sourcemap, and installs the new
tool. It reports success only when the new tool runs.

## None (Roblox Script Sync)

`loren init my-game --tool none` uses Studio's built-in [Script Sync](https://create.roblox.com/docs/scripting/sync):
no Rojo, no Argon, no project file (`.loren.json` marks the project). Only Folders sync, so the runtime lives
inside four synced folders:

| Directory (sync it to the Studio Folder of the same path) | Holds |
| :--- | :--- |
| `ReplicatedStorage/Shared` | the shim `Loren.luau`, `LorenRuntime/`, `LorenTypes.luau` |
| `ReplicatedStorage/LorenPackages` | `Promise.luau` |
| `ServerScriptService/Server` | `Server.server.luau`, `LorenServer/`, `Services/`, `LorenServerTypes.luau` |
| `StarterPlayer/StarterPlayerScripts/Client` | `Client.local.luau` (a LocalScript), `Controllers/` |

In Studio, create those Folders, right-click each one > **Sync to…**, pick its directory and choose **Keep Disk**;
then press Play (the project's README has the steps). Autocomplete: Luau-LSP in plugin mode with the "Luau Language
Server Companion" Studio plugin. `make`, `inject`, `types`, `update` and `doctor` work as usual, without a sourcemap;
`loren update` rewrites the files and Studio picks them up. `migrate` to or from Script Sync is not automated yet.

## License

MIT

<p align="center">
  <img src="https://raw.githubusercontent.com/fabideveloper/Loren-Framework/main/assets/logo-readme.png" width="220" alt="Loren logo">
</p>

# Loren CLI

The command-line tool for [Loren](https://fabideveloper.github.io/Loren-Framework/), a Luau framework for Roblox.
It creates projects for **Rojo**, **Argon** or **Roblox Script Sync** (built into Studio), adds Services,
Controllers and packages, and updates a project's Loren runtime.

> **2.0 is in beta.** It's on the `next` tag. `latest` is still 1.5.1 until 2.0 is stable.

## Install

```bash
npm i -g loren-framework@next   # the 2.0 beta, Node 18 or newer
npm i -g loren-framework        # 1.5.1, the current stable
```

For Rojo or Argon you also need [Rokit](https://github.com/rojo-rbx/rokit), which `loren init` uses to install the
tool, and the Rojo or Argon plugin in Studio (`rojo plugin install` / `argon plugin install`). Existing projects with
an `aftman.toml` or `foreman.toml` can keep using Aftman or Foreman (Rokit reads those files too).

## Start a project

```bash
loren init my-game              # asks Rojo, Argon or None (Script Sync)
loren init my-game --tool argon --yes
cd my-game
loren serve                     # then connect the plugin in Studio and press Play
```

`init` writes the runtime (`loren/`), the bundled Promise, `src/` with a bootstrap, an example Service and an
example Controller, `rokit.toml`, `.gitignore` and `.vscode/settings.json`. Then it installs the toolchain and
builds the sourcemap. `--no-tools` skips those two steps, which helps offline or in CI.

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

- Commands that touch Rojo or Argon take `--tool rojo|argon|none`. Without it, the tool comes from `.loren.json`
  (Script Sync), then `rokit.toml` / `aftman.toml` / `foreman.toml`, then whatever is installed.
- Module and package names have to be Luau identifiers. Project names for `init` may also use spaces, `-` and `.`.
- `make`, `inject` and `add` never overwrite anything without `--force`. The old copy goes to `.loren-backup/`.
- A failed step exits non-zero.
- Nothing prompts without a terminal. Pass `--yes`.

**Packages.** `loren add evaera/roblox-lua-promise` is refused, because Promise is already bundled in
`loren_packages/Promise` and the runtime needs it. Try `loren add howmanysmall/Janitor` instead. A package is a
snapshot: no dependency resolution, no lockfile. Pin a version with `#tag`, and require it with
`require(ReplicatedStorage.LorenPackages.<Alias>)`.

**Typed dependencies (optional).** `LorenTypes` (shared) and `LorenServerTypes` (server) list your module names.
The templates show the pattern: `Dependencies = { "Name" } :: { Types.ClientDependencyName }`, then
`local deps: Types.ClientDeps = self.Dependencies :: any`. `make`, `inject`, `add` and `refresh` keep them current.

## Updating

There are two separate things to update:

- **The CLI:** `npm i -g loren-framework@next` during the beta.
- **A project's runtime:** run `loren update` in the project root. It replaces `loren/`, writes the shim
  (`src/shared/Loren.luau`), patches `default.project.json`, puts the bundled Promise in `loren_packages/Promise`
  (without its test files), regenerates the types and the sourcemap, and runs the middleware check. Replaced files
  are backed up to `.loren-backup/`. Your Services and Controllers aren't touched, except for the optional
  middleware rewrite below.

**From 1.5.1:** your Services and Controllers run unchanged. `loren update --dry-run` shows the plan, and
`loren update` applies it. If you wrote middleware in colon style (`function X.Middleware:Buy(player)`), `update`
and `doctor --fix` offer to rewrite it to dot style (`function X.Middleware.Buy(player)`). That needs a
confirmation or `--yes`. Then press Play in Studio and read Loren's boot report.

**Between 2.x versions:** update the CLI, then run `loren update` in each project. Running it twice is safe.

## Rojo or Argon

Loren works with both. Here's what differs (Loren sets it up for you):

| | Rojo | Argon |
| :--- | :--- | :--- |
| `loren serve` | `rojo serve default.project.json` | `argon serve default.project.json --sourcemap` |
| Sourcemap | `rojo sourcemap ... -o sourcemap.json`; Luau-LSP regenerates it | `argon sourcemap ...`; Argon keeps it fresh while serving |
| `.vscode/settings.json` | `luau-lsp.sourcemap.autogenerate: true` | `false` (Argon writes it) |

`loren migrate` rewrites the toolchain manifest, the Luau-LSP settings and the sourcemap, then installs the new
tool. It only reports success once the new tool runs.

## Script Sync (`--tool none`)

`loren init my-game --tool none` uses Studio's built-in [Script Sync](https://create.roblox.com/docs/scripting/sync).
There's no Rojo, no Argon and no project file (`.loren.json` marks the project). Only Folders sync, so the
runtime lives inside four synced folders:

| Directory (sync it to the Studio Folder of the same path) | Holds |
| :--- | :--- |
| `ReplicatedStorage/Shared` | the shim `Loren.luau`, `LorenRuntime/`, `LorenTypes.luau` |
| `ReplicatedStorage/LorenPackages` | `Promise.luau` |
| `ServerScriptService/Server` | `Server.server.luau`, `LorenServer/`, `Services/`, `LorenServerTypes.luau` |
| `StarterPlayer/StarterPlayerScripts/Client` | `Client.local.luau` (a LocalScript), `Controllers/` |

In Studio, create those Folders, right-click each one > **Sync to…**, pick its directory and choose **Keep Disk**.
Then press Play (the project's README has the steps). For autocomplete, use Luau-LSP in plugin mode with the
"Luau Language Server Companion" Studio plugin. `make`, `inject`, `types`, `update` and `doctor` work as usual,
without a sourcemap, and Studio picks up the files `loren update` rewrites. `migrate` to or from Script Sync
isn't automated yet.

## License

MIT

---
title: CLI
sidebar_label: CLI
sidebar_position: 6
description: Every loren command and option, with an example of each.
---

# CLI

```bash
loren --help
loren update --help
```

The `loren` command creates projects, adds modules and packages, and keeps a project's runtime current. Install it
with `npm i -g loren-framework@next` during the beta (see [Installation](./getting-started/installation.md)).
`loren --version` (or `-v`) prints the CLI version.

## Commands at a glance

| Command | What it does |
|---|---|
| [`loren init <name>`](#loren-init) | Create a project for Rojo, Argon or Script Sync |
| [`loren serve`](#loren-serve) | Start Rojo or Argon (alias: `loren ignite`) |
| [`loren make <type> <Name>`](#loren-make) | Create a Service or Controller from the template |
| [`loren inject <type> <Name>`](#loren-inject) | Copy a premade module into the project |
| [`loren add <repo> [Alias]`](#loren-add) | Download a GitHub repository into `loren_packages` |
| [`loren refresh`](#loren-refresh) | Rebuild the type files, then the sourcemap |
| [`loren types`](#loren-types) | Rebuild the type files only |
| [`loren update`](#loren-update) | Update this project's runtime to the CLI's |
| [`loren doctor`](#loren-doctor) | Check your setup, the project and your middleware |
| [`loren migrate`](#loren-migrate) | Switch a project between Rojo and Argon |

## Rules every command follows

**Run it in the project root.** That's the folder with `default.project.json`, or with `.loren.json` for a Script
Sync project. Only `init`, `doctor` and `inject --list` work anywhere.

**How Loren picks the sync tool.** Commands that touch Rojo or Argon take `--tool rojo`, `--tool argon` or
`--tool none`. Without it, Loren looks in this order:

1. `.loren.json` with `"tool": "none"` (Script Sync). This always wins.
2. `rokit.toml`, then `aftman.toml`, then `foreman.toml`. If one lists both Rojo and Argon, Argon wins.
3. Whichever tool is installed, Rojo first.

**Module and package names are Luau identifiers.** Letters, digits and `_`, not starting with a digit, and not a Luau
keyword. Services and Controllers are usually PascalCase, and `loren make` warns if yours isn't. Project names for
`loren init` may also use spaces, `-` and `.` (see [`loren init`](#loren-init)).

**Nothing is overwritten without `--force`.** `make`, `inject` and `add` refuse to replace an existing module or
package. With `--force` the old copy goes to `.loren-backup/<timestamp>/` first. `update`, `migrate` and
`doctor --fix` back up what they change the same way.

**No questions without a terminal.** In CI or a script, commands never wait for input. `init` picks Rojo unless you
pass `--tool`. `update`, `migrate` and `doctor --fix` stop and ask you to pass `--yes`.

**Exit codes.** 0 when everything worked, 1 when a step failed. `update` and `doctor --fix` exit with 2 when they
needed `--yes`.

**Update check.** When you run a command in a terminal, the CLI sometimes checks npm for a newer version and prints a
note. It only looks at the `latest` tag, so during the beta it won't tell you about new betas. Set
`LOREN_NO_UPDATE_CHECK=1` or `NO_UPDATE_NOTIFIER=1` to turn it off.

## Project setup

### `loren init`

```bash
loren init my-game
loren init my-game --tool argon
loren init my-game --tool none --yes
```

Creates the folder `my-game` with the runtime, a bootstrap for each side, an example Service and an example
Controller. For Rojo and Argon it also writes `rokit.toml`, installs the tool and builds the sourcemap.

| Option | What it does |
|---|---|
| `--tool <tool>` | `rojo`, `argon` or `none` (Script Sync). Without it, `init` asks. |
| `-y`, `--yes` | Never asks. Picks Rojo unless `--tool` says otherwise, and passes `--no-trust-check` to Rokit or Aftman. |
| `--no-tools` | Skips the tool install and the sourcemap. Run `rokit install` and `loren refresh` later. |

The folder must not exist yet, or must be empty. If writing the project fails, `init` removes what it made. If only
the tool install or the sourcemap fails, the project stays and `init` exits with 1. See
[Create a project](./getting-started/new-project.md) for the whole walkthrough.

### `loren serve`

```bash
loren serve
```

Runs `rojo serve default.project.json`, or `argon serve default.project.json --sourcemap` with Argon, and shows its
output until you press Ctrl+C. `loren ignite` does the same thing. With Script Sync there's nothing to serve, so it
prints a reminder and exits.

| Option | What it does |
|---|---|
| `--tool <tool>` | Use this tool instead of the detected one. |

### `loren migrate`

```bash
loren migrate
loren migrate --to argon --yes
```

Switches a project between Rojo and Argon. It rewrites the tool line in `rokit.toml` (or `aftman.toml`,
`foreman.toml`), updates the Luau-LSP settings in `.vscode/settings.json`, installs the new tool and rebuilds the
sourcemap with it. It only reports success once the new tool runs.

| Option | What it does |
|---|---|
| `--to <tool>` | `rojo` or `argon`. Without it, Loren switches to the other one. |
| `-y`, `--yes` | Don't ask for confirmation. |

Moving to or from Script Sync isn't automated yet. Make a new project with `loren init <name> --tool none` (or
`--tool rojo`) and move your Services and Controllers into it.

## Modules

### `loren make`

```bash
loren make service ShopService
loren make controller ShopController
```

Creates `src/server/Services/ShopService.luau` or `src/client/Controllers/ShopController.luau` from the template, then
rebuilds the type files and the sourcemap. In a Script Sync project the files go to
`ServerScriptService/Server/Services/` and `StarterPlayer/StarterPlayerScripts/Client/Controllers/`.

| Option | What it does |
|---|---|
| `-f`, `--force` | Replace a module with that name (backed up first). |
| `--tool <tool>` | The tool used for the sourcemap. |

`make` refuses a name that's already used by a module of the other kind, because a Service and a Controller with the
same name clash in `Dependencies`.

### `loren inject`

```bash
loren inject --list
loren inject service PointsService
loren inject controller PointsController
loren inject shared ExampleShared
```

Copies a premade module into `Services/`, `Controllers/` or the shared folder, then rebuilds the type files and the
sourcemap. The CLI ships three:

| Premade | Type | What it is |
|---|---|---|
| `PointsService` | service | Points per player on the server. Clients read them with `GetPoints` and listen to `PointsChanged`. |
| `PointsController` | controller | Prints the player's points. Needs `PointsService`. |
| `ExampleShared` | shared | An empty module both sides can require. |

Your own premades go in `loren_premade/services`, `loren_premade/controllers` and `loren_premade/shared` in the project.
Loren looks there first, so a project premade with the same name wins. A premade can be a file or a folder.

| Option | What it does |
|---|---|
| `-l`, `--list` | List the premades. Add a type to filter: `loren inject service --list`. |
| `-f`, `--force` | Replace a module with that name (backed up first). |
| `--tool <tool>` | The tool used for the sourcemap. |

### `loren add`

```bash
loren add howmanysmall/Janitor
loren add user/repo#v1.2.0 MyLib
loren add https://github.com/user/repo
```

Downloads a snapshot of a GitHub repository into `loren_packages/<Alias>`. Require it with
`require(ReplicatedStorage.LorenPackages.<Alias>)`.

- The alias defaults to the repository name without a `roblox-lua-` prefix, turned into a Luau identifier if needed.
- `#ref` pins a branch, tag or commit. Without it you get the default branch.
- The download goes to a temporary folder first, so a failed or empty download changes nothing.
- It's a snapshot: no dependency resolution and no lockfile. Run it again with `--force` to update.
- Promise is already bundled, and the runtime needs it, so `loren add` refuses to replace `loren_packages/Promise`
  unless you pass `--force`.
- If the package has no `default.project.json` or `init.lua(u)` at its root, Loren warns that requiring it may not
  work.
- In a Script Sync project, test files (`*.spec.lua`, `*.spec.luau`) are left out, since Script Sync would put them
  in your place.

| Option | What it does |
|---|---|
| `-f`, `--force` | Replace a package with that name (backed up first). |
| `--tool <tool>` | The tool used for the sourcemap. |

## Keeping things current

### `loren refresh`

```bash
loren refresh
loren refresh --watch
```

Rebuilds the type files, then `sourcemap.json`. Run it after you add, rename or delete files by hand. `make`,
`inject` and `add` already do it for you.

| Option | What it does |
|---|---|
| `-w`, `--watch` | Keep running. Rebuild the types whenever a Service or Controller changes, and the sourcemap when files are added, removed or renamed. Ctrl+C stops it. |
| `--tool <tool>` | The tool used for the sourcemap. |

### `loren types`

```bash
loren types
```

Rebuilds `LorenTypes.luau` and `LorenServerTypes.luau` from your Services and Controllers, without touching the
sourcemap. These files list your module names as Luau types, for autocomplete and typo checks in `Dependencies`.
See [Project structure](./getting-started/project-structure.md#generated-type-files).

### `loren update`

```bash
loren update --dry-run
loren update
```

Brings this project's runtime to the version bundled with your CLI. It updates the project, not the CLI. To update the
CLI, run `npm i -g loren-framework@next` during the beta.

It replaces `loren/` (or, with Script Sync, `LorenRuntime` and `LorenServer`), writes the shim, patches
`default.project.json`, makes sure the bundled Promise is in place, rebuilds the type files and the sourcemap, and
runs the middleware check. It works on 1.5.1 projects and on 2.x projects. Running it twice is safe.

| Option | What it does |
|---|---|
| `--dry-run` | Print the plan and the middleware check. Change nothing. |
| `-y`, `--yes` | Don't ask, including for the middleware rewrite. |
| `--no-native` | Install the runtime with its `@native` attributes removed. |
| `--tool <tool>` | The tool used for the sourcemap. `--tool none` skips it. |

If the project's runtime is newer than the CLI's, `update` stops and tells you to update the CLI first. See
[Upgrading from 1.5.1](./getting-started/upgrading.md) for a full run.

### `loren doctor`

```bash
loren doctor
loren doctor --fix
```

Checks your setup and prints one line per check:

- Node is 18 or newer, and a toolchain manager (Rokit, Aftman or Foreman) is installed.
- The project's sync tool runs.
- The runtime is in place: the shim is the current one, `default.project.json` maps `LorenRuntime` and `LorenServer`,
  and Promise is there.
- The Luau-LSP sourcemap setting matches the tool.
- With Script Sync: the runtime folders and `Promise.luau` exist, and no client script is named `*.client.luau`.
- Your code: colon-style middleware, reserved Client method names, `Middleware` or `Spec` keys that match no member,
  and Service keys named `Spec` or `ClientEvents` that look like your own data.

Outside a project it only checks Node and the toolchain manager.

```text
(LORENঌ) Middleware lint: 1 issue.
  src/server/Services/ShopService.luau:6 [fixable] ShopService.Middleware:Buy is colon-style. Loren calls middleware as (player, ...args) without self, so 2.0 denies every Buy call. Dot style: function ShopService.Middleware.Buy(player, itemId)
(LORENঌ) Run `loren doctor --fix` to rewrite colon-style middleware to dot style.
```

| Option | What it does |
|---|---|
| `--fix` | Offer to rewrite colon-style middleware to dot style. The old files are backed up. |
| `-y`, `--yes` | Apply the fix without asking. |

`doctor` exits with 1 if a check failed or colon-style middleware is left. Warnings alone don't fail it.

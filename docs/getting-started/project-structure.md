---
title: Project structure
sidebar_label: Project structure
sidebar_position: 3
slug: /project-structure
description: Every file loren init creates, where it ends up in Studio, and which ones you edit.
---

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

# Project structure

You write code in two folders: `Services` for the server and `Controllers` for the client. Everything else is set up
and kept current by the CLI.

## The tree

<Tabs groupId="tool">
<TabItem value="rojo" label="Rojo" default>

```text
my-game/
├── default.project.json     where each folder goes in Studio
├── rokit.toml               pins the Rojo version (rokit install)
├── selene.toml              linter settings
├── sourcemap.json           generated for autocomplete, git-ignored
├── .gitignore
├── .vscode/settings.json    Luau-LSP settings
├── loren/                   the Loren runtime (loren update replaces it)
│   ├── shared/
│   └── server/
├── loren_packages/
│   └── Promise/             bundled, the runtime needs it
└── src/
    ├── shared/
    │   ├── Loren.luau       the shim you require
    │   └── LorenTypes.luau  generated
    ├── server/
    │   ├── Server.server.luau
    │   ├── LorenServerTypes.luau  generated
    │   └── Services/
    │       └── ExampleService.luau
    └── client/
        ├── Client.client.luau
        └── Controllers/
            └── ExampleController.luau
```

</TabItem>
<TabItem value="argon" label="Argon">

The same files as Rojo, with two differences:

- `rokit.toml` pins Argon instead of Rojo.
- `.vscode/settings.json` sets `luau-lsp.sourcemap.autogenerate` to `false`, because Argon writes `sourcemap.json`
  itself while `loren serve` runs.

```text
my-game/
├── default.project.json
├── rokit.toml               pins the Argon version
├── selene.toml
├── sourcemap.json           written by Argon, git-ignored
├── .gitignore
├── .vscode/settings.json
├── loren/
├── loren_packages/
└── src/
    ├── shared/
    ├── server/
    └── client/
```

</TabItem>
<TabItem value="none" label="Script Sync">

Script Sync only syncs Folders, so there's no project file. The folders on disk are named after where they go in
Studio, and the runtime lives inside them.

```text
my-game/
├── .loren.json              marks this as a Script Sync project
├── README.md                the Studio sync steps
├── .gitignore
├── .vscode/settings.json    Luau-LSP in plugin mode
├── ReplicatedStorage/
│   ├── Shared/
│   │   ├── Loren.luau       the shim you require
│   │   ├── LorenTypes.luau  generated
│   │   └── LorenRuntime/    the shared runtime
│   └── LorenPackages/
│       └── Promise.luau
├── ServerScriptService/
│   └── Server/
│       ├── Server.server.luau
│       ├── LorenServerTypes.luau
│       ├── LorenServer/     the server runtime
│       └── Services/
│           └── ExampleService.luau
└── StarterPlayer/
    └── StarterPlayerScripts/
        └── Client/
            ├── Client.local.luau
            └── Controllers/
                └── ExampleController.luau
```

`.loren.json` looks like this:

```json title=".loren.json"
{
    "tool": "none",
    "layout": "scriptsync",
    "runtime": "2.0.0"
}
```

</TabItem>
</Tabs>

## Where things land in Studio

With Rojo or Argon, `default.project.json` maps each folder to a place in Studio:

| Folder | In Studio | What it is |
|---|---|---|
| `src/shared` | `ReplicatedStorage.Shared` | Code both sides can require, plus the shim |
| `loren_packages` | `ReplicatedStorage.LorenPackages` | Packages from `loren add`, and Promise |
| `loren/shared` | `ReplicatedStorage.LorenRuntime` | The runtime both sides run |
| `src/server` | `ServerScriptService.Server` | Your server bootstrap and Services |
| `loren/server` | `ServerScriptService.LorenServer` | The server-only runtime. Clients never get it. |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` | Your client bootstrap and Controllers |

With Script Sync the folders on disk already have those names. The one difference is that the runtime sits inside the
synced folders: `ReplicatedStorage.Shared.LorenRuntime` and `ServerScriptService.Server.LorenServer`.

When the server boots, it also creates `ReplicatedStorage.LorenNet`: a Folder with a `State` attribute and two remotes,
`Reliable` (a RemoteEvent) and `Unreliable` (an UnreliableRemoteEvent). Loren sends everything through those two. Leave
them alone.

## The shim

Your code requires Loren from the same place as in 1.5.1:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)
```

`Shared/Loren.luau` is a **shim**: a six-line module that finds the real runtime (`LorenRuntime` next to it, or in
`ReplicatedStorage`) and returns it. Don't edit it. `loren update` rewrites it, and `loren doctor` complains if it
changed.

## Services and Controllers

Put Services in `Services/` and Controllers in `Controllers/`. `loren make` creates them there:

```bash
loren make service ShopService
loren make controller ShopController
```

The bootstrap registers the direct children of each folder. A ModuleScript inside a sub-folder is skipped, and Studio
shows a warning that names it. To register those too, pass `{ Recursive = true }`:

```lua title="src/server/Server.server.luau"
Loren.AddServices(script.Parent.Services, { Recursive = true })
```

A Service and a Controller can't share a name. `loren make` refuses it, because the two would clash in
`Dependencies`.

## Generated type files

`LorenTypes.luau` (shared) and `LorenServerTypes.luau` (server only) list the names of your Services and Controllers
as Luau types. They give you autocomplete and typo checks in `Dependencies`. They hold no code: each one ends with
`return table.freeze({})`.

`loren make`, `inject`, `add`, `refresh`, `types` and `update` rewrite them, so don't edit them. Using them is
optional. See [Dependencies](../core-concepts/dependency-injection.md) for the pattern.

## Packages and premades

- `loren add user/repo` downloads a GitHub repository into `loren_packages/<Name>`. Require it with
  `require(ReplicatedStorage.LorenPackages.<Name>)`. Promise is bundled, and `loren add` refuses to replace
  `loren_packages/Promise` unless you pass `--force` (the runtime needs it).
- `loren inject` copies a premade (a ready-made module) into your project. It looks in your own `loren_premade/services`,
  `loren_premade/controllers` and `loren_premade/shared` folders first, then in the premades that ship with the CLI.
  New projects don't have a `loren_premade/` folder. Create one if you want your own premades.

## Backups

`.loren-backup/` appears the first time the CLI replaces something: `loren update`, `loren migrate`,
`loren doctor --fix`, or any `--force`. Each run gets a timestamped folder with the old files at their old paths. It's
git-ignored. Delete it when you don't need it.

## Next

[Your first service](./first-service.md).

---
sidebar_position: 3
title: Project Structure
---

# Project Structure

Running `loren init MyGame` scaffolds a complete, sync-ready workspace. Here is what lives where and how it maps into Roblox.

## The folder tree

```
MyGame/
├── default.project.json   # Rojo/Argon project mapping
├── aftman.toml            # toolchain pins (rojo or argon)
├── sourcemap.json         # generated; powers Luau-LSP autocomplete
├── .vscode/settings.json  # Luau-LSP wired to the sourcemap
├── loren_packages/        # external modules added via `loren add`
├── loren_premade/         # your reusable templates for `loren inject`
│   ├── services/
│   ├── controllers/
│   └── shared/
└── src/
    ├── shared/            # the Loren module + anything shared
    ├── server/
    │   └── Services/      # your Services (created by `loren make service`)
    └── client/
        └── Controllers/   # your Controllers (`loren make controller`)
```

## How it maps into Roblox

The `default.project.json` projects your `src` folders into the DataModel:

| Source folder      | Roblox location                                  |
| :----------------- | :----------------------------------------------- |
| `src/shared`       | `ReplicatedStorage.Shared`                       |
| `loren_packages`   | `ReplicatedStorage.LorenPackages`                |
| `src/server`       | `ServerScriptService.Server`                     |
| `src/client`       | `StarterPlayer.StarterPlayerScripts.Client`      |

This is why the Loren module is required as `ReplicatedStorage.Shared.Loren` from both boundaries — it lives in `src/shared`, which is replicated to every client.

:::warning Don't restructure src/ by hand
The CLI relies on the scaffolded folder layout. Renaming or moving the `src` folders (or their `Services`/`Controllers` subfolders) will break commands like `loren make` and stop the framework from resolving modules.
:::

:::tip Sourcemap stays fresh
`loren make`, `loren inject`, and `loren add` all regenerate `sourcemap.json` automatically. If you add or rename files by hand, run [`loren refresh`](./cli-reference.md) to restore autocomplete.
:::

## Where new modules land

- **`loren make service <Name>`** → `src/server/Services/<Name>.luau`
- **`loren make controller <Name>`** → `src/client/Controllers/<Name>.luau`
- **`loren inject service|controller|shared <Name>`** → copies from `loren_premade/<type>` into the matching `src` folder.
- **`loren add <user/repo> [alias]`** → clones into `loren_packages/<alias>`.

Next, see the [Lifecycle](./lifecycle.md) page to understand how these modules boot.

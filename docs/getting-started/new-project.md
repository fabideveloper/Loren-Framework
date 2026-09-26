---
title: Create a project
sidebar_label: Create a project
sidebar_position: 2
description: Make a new Loren project with loren init, connect it to Studio and press Play.
---

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

# Create a project

```bash
loren init my-game
```

Loren asks which sync tool you want: Rojo, Argon, or None (Studio's built-in Script Sync). Rojo is the default. Then
it writes the project, installs the tool and builds the sourcemap. A **sourcemap** is a file that tells your editor
where each script ends up in Studio, so autocomplete works.

To skip the question, pass the tool:

```bash
loren init my-game --tool argon
loren init my-game --tool none --yes
```

| Option | What it does |
|---|---|
| `--tool rojo`, `--tool argon`, `--tool none` | Picks the sync tool. `none` means Studio's Script Sync. |
| `-y`, `--yes` | Never asks anything. Without `--tool` it picks Rojo. It also tells Rokit to skip its trust prompt. |
| `--no-tools` | Skips installing the tool and building the sourcemap. Useful offline or in CI. Run `rokit install` later. |

The name becomes a folder in the current directory. It can use letters, digits, spaces, `_`, `-` and `.`, and the
folder must not exist yet (an empty folder is fine). If writing the project fails, `init` removes what it made. If
only a later step fails, like the tool install or the sourcemap, the project stays and `init` exits with 1.

Here's what a Rojo project prints with `--no-tools`:

```text
(LORENঌ) Creating "my-game" (Rojo)...
(LORENঌ) Types are up to date.
(LORENঌ) Skipped the toolchain install and the sourcemap (--no-tools).
(LORENঌ) Project "my-game" is ready.

Next:
  cd my-game
  rokit install     (installs the sync tool)
  loren serve       (then connect the Rojo plugin in Studio and press Play)
```

## What you get

Every project starts with the Loren runtime, a bootstrap script for each side, one example Service and one example
Controller. The server bootstrap looks like this:

```lua title="src/server/Server.server.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

Loren.AddServices(script.Parent.Services)

-- expect() rethrows a failed boot here, so it can never fail silently.
Loren.SetOnFire():expect()
```

`Loren.AddServices` registers every ModuleScript in the `Services` folder. `Loren.SetOnFire()` starts Loren (the boot).
The client bootstrap is the same with `AddControllers` and the `Controllers` folder.

[Project structure](./project-structure.md) walks through every file and where it lands in Studio.

## Connect Studio

<Tabs groupId="tool">
<TabItem value="rojo" label="Rojo" default>

```bash
cd my-game
loren serve
```

`loren serve` runs `rojo serve default.project.json` and keeps running until you press Ctrl+C. In Studio, open the Rojo
plugin and click **Connect**. If you don't have the plugin yet, run `rojo plugin install` once.

Luau-LSP in VS Code rebuilds the sourcemap on its own with Rojo (`.vscode/settings.json` turns that on).

</TabItem>
<TabItem value="argon" label="Argon">

```bash
cd my-game
loren serve
```

`loren serve` runs `argon serve default.project.json --sourcemap`, so Argon keeps the sourcemap fresh while it runs. In
Studio, open the Argon plugin and connect. If you don't have the plugin yet, run `argon plugin install` once.

</TabItem>
<TabItem value="none" label="Script Sync">

There's no server to start. You link four Studio Folders to four folders on disk, once per place:

1. Open your place in Studio. In the Explorer, create these Folders if they're missing:
   `ReplicatedStorage.Shared`, `ReplicatedStorage.LorenPackages`, `ServerScriptService.Server` and
   `StarterPlayer.StarterPlayerScripts.Client`.
2. Right-click each Folder, choose **Sync to…**, and pick the matching folder of your project:

   | Studio Folder | Project folder |
   |---|---|
   | `ReplicatedStorage.Shared` | `ReplicatedStorage/Shared/` |
   | `ReplicatedStorage.LorenPackages` | `ReplicatedStorage/LorenPackages/` |
   | `ServerScriptService.Server` | `ServerScriptService/Server/` |
   | `StarterPlayer.StarterPlayerScripts.Client` | `StarterPlayer/StarterPlayerScripts/Client/` |

3. When Studio shows the conflict dialog, choose **Keep Disk**.

`loren init` prints these steps too, and puts them in the project's `README.md`. Roblox's own guide is
[Script Sync](https://create.roblox.com/docs/scripting/sync).

A few things to know about Script Sync:

- It only syncs scripts and Folders. Attributes and tags on scripts are dropped, so keep those on other instances.
- Client scripts must be `*.local.luau` (a LocalScript). A `*.client.luau` file becomes a Script with RunContext
  Client, which runs twice from StarterPlayerScripts. `loren doctor` flags it.
- For autocomplete, use the Luau Language Server extension with the "Luau Language Server Companion" Studio plugin.
  There's no sourcemap.

</TabItem>
</Tabs>

## Press Play

Press **Play** in Studio. When everything started, Loren prints one line per side in the Output window:

```text
(LORENঌ) Burning on Server: 1 service, 0 routes, 4 ms
(LORENঌ) Burning on Client: 1 controller, 0 services, 180 ms
```

"Burning" is Loren's word for "started". The server line counts your Services and routes (a **route** is one network
member: a Client method, a Signal or a ClientEvent). The example Service has none yet, so it's 0. The client line counts
Controllers and the Services it can reach. The last number is how long the boot took on your machine, so yours will
differ.

If something is wrong, you get one report that lists every problem instead of the line above.
[Reading the boot report](../faq.md#reading-the-boot-report) explains it.

## Next

[Your first service](./first-service.md): add a Service that clients can call, and a Controller that calls it.

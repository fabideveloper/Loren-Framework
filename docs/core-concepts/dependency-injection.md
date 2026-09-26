---
title: Dependencies
sidebar_label: Dependencies
sidebar_position: 3
description: How modules ask for each other by name, and the order Loren starts them in.
---

List what a module needs in `Dependencies`. Loren starts those first and puts them in `self.Dependencies`.

```lua title="src/server/Services/InventoryService.luau"
local InventoryService = {
	Dependencies = { "DataService" },
}

function InventoryService:LorenIgnite()
	local Data = self.Dependencies.DataService
	-- DataService:LorenIgnite() has already run here
end

return InventoryService
```

You never write a `require` path to another Service or Controller. Move a module to another folder and nothing breaks, as long as its name stays the same.

## The rules

- `Dependencies` is a list of names: `{ "DataService", "PointsService" }`. Anything else fails the boot.
- On the server, every name must be a registered Service. A missing one fails the boot, with a suggestion when it looks like a typo:

  ```
  InventoryService.Dependencies: 'DataServce' is not a registered Service. Did you mean 'DataService'?
  ```

- On the client, a name can be a Controller or a networked Service. Anything else is a warning and a placeholder. See [Controllers](./controllers.md#dependencies-on-the-client).
- A name listed twice is a warning. The second one is ignored.
- `self.Dependencies` only holds the names you listed. Reading another name returns `nil`, and Studio prints a warning once: `InventoryService reads undeclared dependency 'PointsService'; add it to InventoryService.Dependencies`.

## Start order

Loren sorts the modules so that each one's dependencies run their `LorenIgnite` (setup) before it does. With these four Services:

| Service | Dependencies |
|---|---|
| `DataService` | none |
| `InventoryService` | `DataService` |
| `PointsService` | `DataService` |
| `ShopService` | `InventoryService`, `PointsService` |

the order is `DataService`, `InventoryService`, `PointsService`, `ShopService`. `LorenIgnite` (setup) runs in that order, one at a time. `LorenBurn` (run) starts in the same order, but each one runs on its own thread, so a `LorenBurn` that yields doesn't hold up the next one.

The order is the same on every run. Loren sorts by name first, so it never depends on table order.

All `Dependencies` tables are filled in before the first `LorenIgnite` runs.

## Cycles

Two modules can depend on each other:

```lua
local MatchService = { Dependencies = { "TeamService" } }
local TeamService = { Dependencies = { "MatchService" } }
```

This works, as it did in 1.5.1, and Loren doesn't warn about it by default. Inside a cycle, `LorenIgnite` and `LorenBurn` run in name order, so `MatchService` sets up before `TeamService`. That means `MatchService:LorenIgnite()` sees a `TeamService` that hasn't set itself up yet.

Use the other half of a cycle in `LorenBurn`, not in `LorenIgnite`. By the time any `LorenBurn` runs, every module's `LorenIgnite` has finished.

Two settings change how cycles are treated. Both work on the server and the client:

```lua
Loren.Configure({
	CycleWarnings = true, -- list each cycle in the boot warnings
	StrictCycles = true, -- fail the boot on any cycle
})
```

With `CycleWarnings`, the boot warnings include a line like:

```
Dependency cycle: MatchService -> TeamService -> MatchService (allowed; inside a cycle, Ignite and Burn run in name order)
```

With `StrictCycles`, the same cycle is a boot error.

## Code that isn't a module

Scripts, tools and other code outside your Services and Controllers can look modules up by name:

```lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

Loren.OnReady():andThen(function()
	local Points = Loren.GetService("PointsService")
	Players.PlayerAdded:Connect(function(player)
		Points:AddPoints(player, 10) -- a welcome bonus
	end)
end)
```

| Function | Server | Client |
|---|---|---|
| `Loren.GetService(name)` | The Service's table. Works right after `AddServices`. | The proxy. Works once the client has the manifest (the Service list from the server), so wait for `OnReady` first. |
| `Loren.GetController(name)` | Raises an error. | The Controller's table, right after `AddControllers`. |
| `Loren.Get(require(module))` | The same table, if it's a registered Service. | The same table, if it's a registered Controller. |

An unknown name raises an error with a suggestion. On the server, `GetService` hands you the table before the boot has filled in its `Signals` and `Dependencies`, so wait for `OnReady` before you call into it.

`Loren.Get` exists for the type checker: `Loren.Get(require(path.to.Module))` returns the module with its own type, and fails loudly if you pass something Loren doesn't know.

## Typed dependencies

`self.Dependencies` is typed `any`, so the type checker can't catch a misspelled name. The CLI generates two type files to help: `LorenServerTypes` for Services and `LorenTypes` for Controllers.

```lua title="src/server/Services/ShopService.luau"
local ServerScriptService = game:GetService("ServerScriptService")
local Types = require(ServerScriptService.Server.LorenServerTypes)

local ShopService = {
	Dependencies = { "PointsService" } :: { Types.ServiceName },
}

function ShopService:LorenIgnite()
	local deps: Types.ServerDeps = self.Dependencies :: any
	local Points = deps.PointsService
end

return ShopService
```

For a Controller, require `ReplicatedStorage.Shared.LorenTypes` and use `Types.ClientDependencyName` and `Types.ClientDeps`. You get autocomplete for names and a type error for a misspelled one. The values are still `any`.

`loren types` regenerates both files. `loren make`, `loren inject`, `loren refresh` and `loren update` do it too. See the [CLI](../cli-reference.md).

---
title: Lifecycle
sidebar_label: Lifecycle
sidebar_position: 4
slug: /lifecycle
description: How Loren boots, what each hook is for, and what the boot report tells you.
---

```lua title="src/server/Server.server.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

Loren.AddServices(script.Parent.Services)

Loren.SetOnFire():expect()
```

`Loren.SetOnFire()` starts Loren. It returns a Promise that resolves with `Loren` once everything is running, or rejects with the boot report if something is wrong. `:expect()` waits for it and rethrows a failed boot, so a broken boot can't go unnoticed. The client script looks the same with `AddControllers`.

Call `Configure`, `AddServices`, `AddControllers` and `AddMiddleware` before `SetOnFire`. Calling `SetOnFire` a second time doesn't start a second boot; you get a Promise for the same one.

The names are themed. Here's what they mean:

| Name | Plain meaning |
|---|---|
| `Loren.SetOnFire()` | Start Loren (boot). |
| `LorenIgnite` | Setup. Runs first, in dependency order, one at a time. Must not yield. |
| `LorenBurn` | Run. Starts after every module ignited, each on its own thread. May yield. |
| `LorenExtinguish` | Stop. Server shutdown only, in reverse order, 25 second budget. |
| `IsOnFire` / `IsReady` | The boot has started / the boot has finished. |
| "Burning on Server" / "Burning on Client" | The line Loren prints when the boot finished. |

## States

`Loren.State` tells you where the boot is:

| State | Meaning | `IsOnFire` | `IsReady` |
|---|---|---|---|
| `Idle` | `SetOnFire` hasn't been called. | `false` | `false` |
| `Booting` | Checking modules, running Ignite and Burn. | `true` | `false` |
| `Ready` | Running. Clients can connect. | `true` | `true` |
| `Failed` | The boot failed. The report says why. | `true` | `false` |
| `ShuttingDown` | The server is closing (server only). | `true` | `true` |

To run code once Loren is up, use `OnReady`. It resolves right away if Loren is already running, rejects if the boot fails, and works even before `SetOnFire` is called:

```lua
Loren.OnReady():andThen(function()
	print("Loren is running")
end)
```

## LorenIgnite (setup)

```lua
local Players = game:GetService("Players")
local points: { [Player]: number } = {}

function PointsService:LorenIgnite()
	Players.PlayerRemoving:Connect(function(player)
		points[player] = nil
	end)
end
```

Use Ignite to set up state and connect events. Loren runs every Ignite in dependency order, one at a time, so when yours runs, everything in your `Dependencies` has already ignited. Cycles are the exception: see [Dependencies](./dependency-injection.md#cycles).

Ignite shouldn't yield. If it does, the boot waits for it and warns:

```
(LORENঌ) ShopService:LorenIgnite yielded; the boot waits for it (move yielding work to LorenBurn)
```

After 30 seconds it warns again. It never gives up unless you set a limit:

```lua
Loren.Configure({ IgniteTimeout = 10 }) -- an Ignite still running after 10 s fails the boot
```

An error in Ignite fails the boot, with the error and the traceback in the report.

## LorenBurn (run)

```lua
function RoundService:LorenBurn()
	while true do
		self:StartRound()
		task.wait(120)
	end
end
```

Burn starts after every module has ignited. Each Burn runs on its own thread, so it can yield, loop or wait on a DataStore without holding anything up.

An error in Burn doesn't fail the boot. Loren logs it and keeps going:

```
(LORENঌ) Service 'RoundService': LorenBurn failed: ...
```

On the server, the network opens once every Burn has started, not when they finish. If a Client method needs something your Burn loads, read [Calls can arrive during LorenBurn](./services.md#calls-can-arrive-during-lorenburn).

## LorenExtinguish (stop)

```lua
local DataStoreService = game:GetService("DataStoreService")
local store = DataStoreService:GetDataStore("Sessions")
local sessions: { [Player]: { Coins: number } } = {}

function SessionService:LorenExtinguish()
	for player, data in sessions do
		store:SetAsync(tostring(player.UserId), data)
	end
end
```

When the server closes, Loren:

1. sets `State` to `ShuttingDown`. Calls that arrive from now on are rejected with `ShuttingDown`,
2. starts every Service's `LorenExtinguish` at the same time, in reverse start order,
3. waits until they all return, for at most 25 seconds,
4. sends whatever is still queued.

If a hook is still running after 25 seconds, Loren warns with its name and moves on. Extinguish is Services only. It doesn't run in offline boots (see Studio modes below).

## The boot line

A good boot prints one line:

```
(LORENঌ) Burning on Server: 4 services, 9 routes, 31 ms
(LORENঌ) Burning on Client: 3 controllers, 2 services, 840 ms
```

Your counts and times will differ. Routes are the network members of your networked Services: Client methods, Signals and ClientEvents. On the client, "services" means the networked Services it can see. An offline boot adds ` (offline)`.

If the boot found something worth fixing but not fatal, one warning block follows:

```
(LORENঌ) Boot warnings on Server (1):
  - ShopService.Middleware.Buyy matches no Client method or ClientEvent and is ignored. Did you mean 'Buy'?
```

## The boot report

When the boot fails, Loren collects every problem it can find first and prints them together, so you fix them in one go:

```
(LORENঌ) Boot failed on Server (2 problems):
  1. RoundService.Signals must be an array of names; it has the key 'Started'; list names only (per-member options go in Spec)
  2. ShopService.Dependencies: 'PointService' is not a registered Service. Did you mean 'PointsService'?
Warnings (1):
  - ShopService.Middleware.Buyy matches no Client method or ClientEvent and is ignored. Did you mean 'Buy'?
```

The report prints in red even if nothing handles the Promise. `SetOnFire()` and `OnReady()` reject with the same text, and `State` becomes `Failed`. Nothing is networked after a failed server boot. Clients see that too, and their own boot fails with `Could not join the server: server boot failed`.

Paste the whole report when you open an issue. The [FAQ](../faq.md) explains the common lines.

## Studio modes

| Mode | What happens |
|---|---|
| Play (server and clients) | The normal boot on both sides. |
| Run (F8) | A server with no players. `IsServer` is `true` and `IsClient` is `false`. `AddControllers` warns and does nothing. |
| Edit mode (plugins, the command bar) | The server boot runs offline: no network, no players, no shutdown hook. Ignite and Burn still run, and firing a Signal does nothing. |

Unit tests can force an offline boot in Play mode with `Loren.Testing.Reset({ Offline = true })`. See [Testing](./testing.md).

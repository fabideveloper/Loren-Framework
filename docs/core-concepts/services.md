---
title: Services
sidebar_label: Services
sidebar_position: 1
description: Server modules that hold your game's state and answer calls from clients.
---

A Service is a ModuleScript that runs on the server. It holds state, applies your game rules and decides what clients may ask for. Here's a whole one:

```lua title="src/server/Services/ShopService.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

local ShopService = {
	Dependencies = { "PointsService" },
	Client = {},
	Signals = { "Purchased" },
}

local PRICES: { [string]: number } = { Sword = 50, Shield = 30 }

-- Server only: other Services can call this, clients can't.
function ShopService:GetPrice(item: string): number?
	return PRICES[item]
end

-- Clients call this as ShopService:Buy("Sword") and get a Promise.
function ShopService.Client:Buy(player: Player, item: string)
	local price = if type(item) == "string" then self.Server:GetPrice(item) else nil
	if price == nil then
		return Loren.Reject("Unknown item")
	end

	local Points = self.Server.Dependencies.PointsService
	if Points:GetPoints(player) < price then
		return Loren.Reject("Not enough points")
	end

	Points:AddPoints(player, -price)
	self.Server.Signals.Purchased:Fire(player, item)
	return item
end

return ShopService
```

`PointsService` is a premade, a ready-made module that ships with the CLI. `loren inject service PointsService` copies it into your project.

## The shape

Every key is optional. Leave out what you don't use.

| Key | What it's for |
|---|---|
| `Dependencies` | Names of other Services this one needs. See [Dependencies](./dependency-injection.md). |
| `Client` | Methods clients can call. |
| `Signals` | Names of messages the server sends to clients. |
| `ClientEvents` | Names of messages clients send to the server, with no reply. New in 2.0. |
| `Middleware` | Checks that run before a Client method or ClientEvent. |
| `Spec` | Optional argument types and per-member options. New in 2.0. |
| `LorenIgnite`, `LorenBurn`, `LorenExtinguish` | Setup, run and stop hooks. See [Lifecycle](./lifecycle.md). |

Loren replaces a few of these at boot. `Signals` and `ClientEvents` become tables of objects, `Dependencies` becomes a name-to-module map, and `Client.Server` is set to the Service. Only the keys you declared are touched.

:::warning Don't freeze these tables
If a Service declares `Dependencies`, `Signals` or `ClientEvents`, Loren has to write to the module table. It also writes `Client.Server`. A frozen table there fails the boot with a message that says which key.
:::

## Registering Services

```lua title="src/server/Server.server.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

Loren.AddServices(script.Parent.Services)

Loren.SetOnFire():expect()
```

`AddServices` takes a folder (it uses the children) or an array of ModuleScripts. The ModuleScript's name is the Service's name.

- Only direct children are registered. ModuleScripts inside sub-folders are skipped, and Studio prints a warning that lists them. Pass `{ Recursive = true }` to include sub-folders: `Loren.AddServices(script.Parent.Services, { Recursive = true })`.
- Each module is required right away. If one fails to load, the error shows up in the boot report instead of stopping the script.
- Two Services with the same name fail the boot, and the report shows both paths.
- Call it before `SetOnFire`. Calling it after raises an error. On a client it does nothing and warns in Studio.

## Client methods

```lua
function ShopService.Client:Buy(player: Player, item: string)
	-- self is ShopService.Client, self.Server is ShopService
end
```

- The first argument is always the player who called. Loren fills it in from the connection, so a client can't pretend to be someone else.
- Everything after `player` comes from the client. Treat it as untrusted: check the type, the range and whether this player is allowed to do it. The [Security](../networking/security.md) page has a checklist.
- Inside a Client method, `self` is the `Client` table. Use `self.Server` to reach the Service, its `Signals` and its `Dependencies`.
- Define Client methods with a colon (`Client:Buy`). The client calls them with a colon too (`ShopService:Buy("Sword")`).

### What the caller gets back

| Your handler | The client's Promise |
|---|---|
| returns values | resolves with them. Several values and `nil` holes are kept. |
| returns a Promise | Loren waits for it. It resolves with the Promise's values. A rejection with `Loren.Reject` becomes `Rejected`; any other rejection becomes `InternalError`. |
| returns or throws `Loren.Reject("msg", data)` | rejects with `"msg"`. The second value, `info`, carries `data`. |
| throws an error | rejects with `(LORENঌ) InternalError [a1b2c3d4]`. The server logs the traceback under that incident id. |
| returns `false, "msg"` | resolves with `false, "msg"`, as in 1.5.1. It isn't a rejection. |
| returns something Loren can't send | rejects with `BadResult`. |

`Loren.Reject` is how you say "no" on purpose. The player sees your message, and the server doesn't log it as a failure. The [Errors](../api-reference/errors.md) page lists every code a call can end with.

Each method has a timeout, 10 seconds unless you change it. See [Calls and promises](../networking/calls.md).

### Server-only methods

Functions on the Service table itself, like `ShopService:GetPrice`, never reach the network. Other Services call them through `Dependencies`:

```lua
local price = self.Dependencies.ShopService:GetPrice("Sword")
```

### Reserved names

A Client method can't be called `Server`, `Signals`, `ClientEvents`, `Properties` or `Try`. Those names are taken on the client proxy. Loren skips such a method and prints a boot warning.

## Signals

List the names, then fire them from anywhere on the server:

```lua
local RoundService = {
	Signals = { "RoundStarted", "Scored" },
}

function RoundService:StartRound(map: string)
	self.Signals.RoundStarted:FireAll(map)
end

function RoundService:Score(player: Player, points: number)
	self.Signals.Scored:Fire(player, points)
end
```

After the boot, each name is an object with `Fire(player, ...)`, `FireAll(...)`, `FireFor(players, ...)` and `FireExcept(playerOrPlayers, ...)`. The `Signals` table is frozen, and a name you didn't declare raises an error that lists the declared ones. Code that checked `self.Signals.X` for `nil` has to check the name list instead. More in [Signals](../networking/signals.md).

## ClientEvents

ClientEvents go the other way: the client fires, the server listens, and nobody waits for a reply.

```lua
local CombatService = {
	ClientEvents = { "Aim" },
}

function CombatService:LorenIgnite()
	self.ClientEvents.Aim:Connect(function(player: Player, direction: any)
		if typeof(direction) ~= "Vector3" then
			return
		end
		-- use direction
	end)
end
```

A listener gets the player first. A Client method and a ClientEvent can't share a name (that fails the boot). A Signal can share a name with either. More in [Client events](../networking/client-events.md).

## Middleware and Spec

`Middleware` runs a check before a Client method or ClientEvent. Write it with a dot, and return `true` to let the call through:

```lua
ShopService.Middleware = {}

function ShopService.Middleware.Buy(player: Player, item: any)
	return type(item) == "string" and #item <= 32
end
```

Anything other than `true` blocks the call, `nil` included. The details and the colon-style trap are in [Middleware](../networking/middleware.md).

`Spec` describes argument types so Loren can check them before your code runs, and it holds per-member options like `Timeout` and `Serial`. See [Typed specs](../networking/typed-specs.md).

## Which Services clients can see

A Service is networked when it has at least one Client method, Signal or ClientEvent. Clients only learn about networked Services. A Service without any of those stays on the server, and a Controller can't depend on it.

## Calls can arrive during LorenBurn

Clients can start calling as soon as every `LorenBurn` (run hook) has started, not when they finish. If your `LorenBurn` yields, a call can arrive before it's done. Guard those methods:

```lua
local DataStoreService = game:GetService("DataStoreService")
local priceStore = DataStoreService:GetDataStore("ShopPrices")

local prices: { [string]: number }? = nil

function ShopService:LorenBurn()
	prices = priceStore:GetAsync("current") or { Sword = 50 }
end

function ShopService.Client:GetPrices(player: Player)
	if prices == nil then
		return Loren.Reject("NotReady")
	end
	return prices
end
```

Setup that doesn't yield belongs in `LorenIgnite`, which always finishes before any client can connect.

## What Loren can't check for you

Loren drops malformed packets and enforces rate limits. It can't know that a Sword costs 50, that a player is out of range, or that a cooldown hasn't passed. A client can call `Buy` with any arguments a normal player could send. Check prices, ownership and cooldowns on the server, in the method. The [Security](../networking/security.md) page goes through it.

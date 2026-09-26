---
title: Controllers
sidebar_label: Controllers
sidebar_position: 2
description: Client modules that run UI, input and effects, and talk to Services through proxies.
---

A Controller is a ModuleScript that runs on each player's client. It handles input, UI and effects, and it talks to Services through proxies.

```lua title="src/client/Controllers/ShopController.luau"
local ShopController = {
	Dependencies = { "ShopService" },
	Signals = { "ItemBought" },
}

function ShopController:LorenBurn()
	local Shop = self.Dependencies.ShopService

	-- A Signal from the server: fired with ShopService.Signals.Purchased:Fire(player, item)
	Shop.Signals.Purchased:Connect(function(item: string)
		self.Signals.ItemBought:Fire(item)
	end)
end

function ShopController:Buy(item: string)
	local Shop = self.Dependencies.ShopService

	return Shop:Buy(item)
		:andThen(function(bought: string)
			print("Bought", bought)
		end)
		:catch(function(message: string)
			warn("Could not buy:", message)
		end)
end

return ShopController
```

## The shape

| Key | What it's for |
|---|---|
| `Dependencies` | Names of Controllers and networked Services this one needs. |
| `Signals` | Names of local signals other Controllers can listen to. They never leave this client. |
| `LorenIgnite`, `LorenBurn` | Setup and run hooks. See [Lifecycle](./lifecycle.md). |

Controllers have no `LorenExtinguish`. Clients don't get a shutdown hook.

## Registering Controllers

```lua title="src/client/Client.client.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

Loren.AddControllers(script.Parent.Controllers)

Loren.SetOnFire():expect()
```

`AddControllers` follows the same rules as `AddServices`: direct children only unless you pass `{ Recursive = true }`, call it before `SetOnFire`, and a duplicate name fails the boot. On the server it does nothing and warns in Studio. That includes Studio's Run mode, which starts a server and no client.

## Dependencies on the client

A name in a Controller's `Dependencies` can be:

- **another Controller.** You get its module table.
- **a networked Service.** You get a proxy (below). A Service is networked when it has at least one Client method, Signal or ClientEvent.
- **anything else.** The boot prints a warning, and the name resolves to a placeholder that raises an error when you touch it.

```
HudController.Dependencies: 'PointService' is not a Controller or a networked Service (a Service is networked when it has a Client method, ClientEvent or Signal); it resolves to a placeholder that raises when used. Did you mean 'PointsService'?
```

It's a warning, not an error, because the client can't tell a typo from a Service that has no network members. The server only tells clients about networked Services.

If a name is both a Controller and a networked Service and some module depends on it, the boot fails. Rename one of them.

## Proxies

A proxy stands in for a Service on the client. It has the Service's Client methods, Signals and ClientEvents, and nothing else.

```lua
local Shop = self.Dependencies.ShopService

-- Call: returns a Promise
Shop:Buy("Sword"):andThen(print)

-- Try: waits, then returns ok plus the values (or ok = false, message, info)
local ok, item = Shop.Try:Buy("Sword")

-- Listen to a Signal
local connection = Shop.Signals.Purchased:Connect(function(item: string)
	print("Purchased", item)
end)

-- Fire a ClientEvent (no reply), if ShopService declares ClientEvents = { "Browse" }
Shop.ClientEvents.Browse:Fire("Swords")
```

- Use a colon for calls. `Shop.Buy("Sword")` raises `Call ShopService:Buy(...) with ':'`, because a dot call would shift every argument by one. A dot call with no arguments, `Shop.GetPrices()`, still works as it did in 1.5.1.
- A name the Service doesn't have raises an error with a suggestion and the list of members. If the name is a Signal or ClientEvent, the error tells you where to find it.
- `Try` has to run on a thread that can yield, like `LorenBurn` or a connected function.

The [Loren API](../api-reference/loren.md#service-proxies) page lists every proxy member, and [Calls and promises](../networking/calls.md) covers timeouts and failures.

## Local signals

When a Controller lists `Signals`, each name becomes a local signal. Other Controllers connect to it through `Dependencies`:

```lua title="src/client/Controllers/HudController.luau"
local HudController = {
	Dependencies = { "ShopController" },
}

function HudController:LorenIgnite()
	self.Dependencies.ShopController.Signals.ItemBought:Connect(function(item: string)
		print("Show a toast for", item)
	end)
end

return HudController
```

Local signals have `Fire`, `Connect`, `Once`, `Wait`, `DisconnectAll` and `Destroy`. They stay on this client.

If your Controller keeps its own signal objects in `Signals` (anything other than a list of names), Loren leaves the table alone, as 1.5.1 did.

## When Controllers start

The client boot waits for the server to finish its own boot. Then:

1. It gets the manifest from the server (the list of networked Services and their members) and builds the proxies.
2. It resolves every Controller's `Dependencies`.
3. It runs every `LorenIgnite`, dependencies first. Proxies don't affect the order, since the server is already running.
4. It starts every `LorenBurn`, each on its own thread.
5. It prints `Burning on Client` and resolves `SetOnFire`.

So by the time any `LorenIgnite` runs, every proxy works and every Service's `LorenIgnite` has finished.

If the server takes long, the client warns after 60 seconds without a running server and after 30 seconds without the manifest. It keeps waiting either way. If the server boot failed, the client boot fails too.

## Signals that arrive before you connect

The server can fire a Signal before your Controller connects to it, for example right when the player joins. Loren keeps up to 64 messages per Signal and replays them in order at your first `Connect`, `Once` or `Wait`. The window closes 10 seconds after the client is ready. Connecting in `LorenIgnite` avoids the question. See [Signals](../networking/signals.md) for `Backlog` and how to turn it off.

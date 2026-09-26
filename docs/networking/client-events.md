---
title: Client events
sidebar_label: Client events
sidebar_position: 3
description: Fire-and-forget messages from a client to a Service, reliable or unreliable.
---

A ClientEvent goes from a client to the server, the opposite way from a [Signal](./signals.md). There's no reply and nothing to wait for. Use it for input that happens often: an aim direction, an emote, a key press. If the client needs an answer, use a [Client method](./calls.md) instead.

## Declare and listen on the server

```lua title="src/server/Services/EmoteService.luau"
local EmoteService = {
	ClientEvents = { "Emote" },
}

local EMOTES = { Wave = true, Dance = true, Point = true }

function EmoteService:LorenIgnite()
	self.ClientEvents.Emote:Connect(function(player: Player, name: any)
		if type(name) ~= "string" or not EMOTES[name] then
			return -- not an emote we know: ignore it
		end
		print(player.Name, "does", name)
	end)
end

return EmoteService
```

The listener gets the `player` first. Loren fills it in from the connection. The values after it are whatever the client sent.

On the server, `self.ClientEvents.Emote` has `Connect`, `Once`, `Wait` (which returns `player, ...`) and `DisconnectAll`. `Fire` raises an error there: the server sends with Signals. A name that isn't in `ClientEvents` errors at your line, the same way `self.Signals` does.

Each listener runs in its own thread, and Loren catches any error it throws. If one errors, the others still run, and Loren logs the error at most once per event every 10 seconds, so a client can't flood your log by making a listener fail on purpose.

## Fire from the client

```lua title="src/client/Controllers/EmoteController.luau"
local EmoteController = {
	Dependencies = { "EmoteService" },
}

function EmoteController:Wave()
	self.Dependencies.EmoteService.ClientEvents.Emote:Fire("Wave")
end

return EmoteController
```

`Fire` returns nothing and doesn't wait. Call it with a colon: `Emote.Fire("Wave")` raises an error, because the dot would shift the arguments. `Connect` on the client raises an error too.

## Validate everything

The `player` argument is real. Every other value comes from the client, and a modified client can send anything: wrong types, long strings, a table where you expect a number. Loren already refuses NaN and infinity, tables nested deeper than 16 levels, and more than 20 arguments. Everything else is up to you. Either check the values in the listener, as `EmoteService` does, or give the event a [typed spec](./typed-specs.md) and let Loren check them.

## Reliable or unreliable

Events are reliable unless you say otherwise:

| | Reliable (default) | Unreliable |
| :--- | :--- | :--- |
| Delivery | Always, in order | May be dropped or arrive out of order |
| Size of one message | Up to 64 KiB | Up to 900 bytes, header included |
| Arguments | Anything you can send in a call | Typed, without `T.Instance` or `T.any` |
| Default limit per player | 75 a second, bursts of 150 | 120 a second, bursts of 60 |
| Coalesced | No | Yes |

An unreliable event is declared in the `Spec`:

```lua title="src/server/Services/AimService.luau"
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)
local T = Loren.T

local AimService = {
	ClientEvents = { "Aim" },
	Spec = {
		Aim = Loren.Event(T.Vector3(1.01), { Unreliable = true }),
	},
}

local aims: { [Player]: Vector3 } = {}

function AimService:GetAim(player: Player): Vector3?
	return aims[player]
end

function AimService:LorenIgnite()
	self.ClientEvents.Aim:Connect(function(player: Player, direction: Vector3)
		aims[player] = direction
	end)
	Players.PlayerRemoving:Connect(function(player)
		aims[player] = nil
	end)
end

return AimService
```

```lua title="src/client/Controllers/AimController.luau"
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AimController = {
	Dependencies = { "AimService" },
}

function AimController:LorenBurn()
	local Aim = self.Dependencies.AimService.ClientEvents.Aim
	RunService.RenderStepped:Connect(function()
		Aim:Fire(Workspace.CurrentCamera.CFrame.LookVector)
	end)
end

return AimController
```

`T.Vector3(1.01)` means "a Vector3 no longer than 1.01, with no NaN or infinity". Loren checks that before the listener runs and drops anything else, so the listener can use `direction` as it is.

An unreliable event without typed arguments, or with `T.Instance` or `T.any`, fails the boot:

```text
AimService.Aim: Unreliable and Coalesce members need typed Args without T.Instance or T.any
```

A `Fire` whose message is over 900 bytes raises an error at your line.

## Coalescing

A coalesced event keeps only the latest `Fire` until the client's next send and drops the older ones. The client sends at most 61 times a second, so `AimController` above, firing every frame at 240 FPS, puts at most 61 aim updates a second on the wire. For state like "where am I aiming", the older values don't matter.

- Unreliable events are coalesced by default. Add `Coalesce = false` to send every `Fire`.
- Reliable events aren't. `Coalesce = true` turns it on. The event then needs typed arguments without `T.Instance` or `T.any`.

This matters for reliable events you fire every frame. The default limit is 75 a second, and the client holds itself to 90% of it. At 60 FPS that fits. At 240 FPS it doesn't, and the extra events are dropped on the client. Use `Coalesce = true` (or an unreliable event) for per-frame input.

## Ordered

`Ordered = true` drops a message that arrives after a newer one from the same player. That's useful when an old value is worse than no value, like a position. It only works on unreliable events; reliable ones already arrive in order, so `Ordered` without `Unreliable` is an error. The order resets after 1 second without messages.

```lua
Spec = {
	Move = Loren.Event(T.Vector3, T.u32, { Unreliable = true, Ordered = true }),
},
```

## Rate limits

Each player has a limit per event (the table above has the defaults). The client knows the limit and holds itself to 90% of it: events over that are dropped on the client, counted in `Loren.GetStats().EventsLost`, and Studio warns once. Events that still arrive over the limit are dropped on the server and counted. Events have no reply, so nothing tells the client.

Change the limit for one event in its spec, or with `Members`:

```lua
Spec = {
	Emote = Loren.Event({ RateLimit = { 2, 4 } }), -- 2 a second, bursts of 4
},
```

```lua
Loren.Configure({
	Members = {
		["EmoteService.Emote"] = { RateLimit = { 2, 4 } },
	},
})
```

## Middleware for events

The `Middleware` table covers ClientEvents too: use the event's name as the key. Return `true` to let the event through. Anything else drops it, silently, since there's no reply to send. See [Middleware](./middleware.md).

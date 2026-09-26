---
title: Signals
sidebar_label: Signals
sidebar_position: 2
description: How a Service sends messages to clients, and how Controllers listen for them.
---

A Signal carries a message from the server to clients. The Service lists the names, Loren creates the objects, and Controllers connect to them through the Service's proxy. For the other direction, client to server, see [Client events](./client-events.md).

## Declare and fire

```lua title="src/server/Services/PointsService.luau"
local PointsService = {
	Client = {},
	Signals = { "PointsChanged", "RoundStarted" },
}

local points: { [Player]: number } = {}

function PointsService:AddPoints(player: Player, amount: number): number
	local total = (points[player] or 0) + amount
	points[player] = total
	self.Signals.PointsChanged:Fire(player, total)
	return total
end

function PointsService:StartRound(round: number)
	self.Signals.RoundStarted:FireAll(round)
end

return PointsService
```

After boot, `self.Signals` holds one object per name. The table is read-only, and a typo errors at your line:

```text
(LORENঌ) PointsService.Signals has no 'PointChanged'. Signals: PointsChanged, RoundStarted
```

There are four ways to fire:

| Call | Who gets it |
| :--- | :--- |
| `Fire(player, ...)` | One player. A player who already left is skipped and counted in `Loren.GetStats().SignalsDropped`. |
| `FireAll(...)` | Every player in the game. |
| `FireFor(players, ...)` | An array of players. |
| `FireExcept(player, ...)` | Everyone except one player. You can also pass an array of players to leave out. |

A first argument that isn't a Player (or an array of them for `FireFor`) errors at your line. Server Signals only send. `Connect`, `Once` and `Wait` on the server raise an error.

## Listen on the client

```lua title="src/client/Controllers/HudController.luau"
local HudController = {
	Dependencies = { "PointsService" },
}

function HudController:LorenIgnite()
	local Points = self.Dependencies.PointsService

	Points.Signals.PointsChanged:Connect(function(total)
		print("Points:", total)
	end)

	Points.Signals.RoundStarted:Once(function(round)
		print("First round I saw:", round)
	end)
end

return HudController
```

The client side of a Signal has four methods:

| Method | What it does |
| :--- | :--- |
| `Connect(fn)` | Calls `fn` with the values of every message. Returns a connection. |
| `Once(fn)` | Like `Connect`, for the next message only. |
| `Wait()` | Yields until the next message and returns its values. Only from code that can yield. |
| `DisconnectAll()` | Disconnects every listener. |

A connection has `Connected` and `Disconnect`. Both `connection:Disconnect()` and `connection.Disconnect()` work, and calling it twice is fine.

```lua
local connection = Points.Signals.PointsChanged:Connect(function(total)
	print("Points:", total)
end)

connection:Disconnect()
print(connection.Connected) -- false
```

Listeners run in the order they connected, each in its own thread, so one that yields doesn't hold up the rest. A listener that errors shows up in the output like any script error, and the others still run. A listener connected during a fire starts with the next message; one disconnected during a fire is skipped. Calling `Fire` on the client raises an error: clients send with [Client events](./client-events.md).

## Messages sent before you connect

A player's client boots a moment after they join. In 1.5.1, anything fired in that gap was lost. 2.0 keeps a backlog: up to 64 messages per signal, held on the client until the first `Connect`, `Once` or `Wait`. Right after that first connect, Loren replays them in order.

The rules:

- The backlog only exists until the first connect. After that, a message with no listeners is dropped, like with a normal Roblox event.
- If nothing connects within 10 seconds of the client finishing its boot (`BacklogWindow`), the backlog is thrown away and that signal stops buffering.
- When the backlog is full, the oldest message goes. Studio warns once, and it's counted in `SignalsDropped`.
- Connecting in `LorenIgnite`, or in `LorenBurn` before it yields, is always in time.

You can change the size per signal in the Service's `Spec`, from 0 to 1024:

```lua title="src/server/Services/RoundService.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

local RoundService = {
	Signals = { "RoundStarted", "Tick" },
	Spec = {
		RoundStarted = Loren.Signal({ Backlog = 1 }), -- a late listener gets only the latest
		Tick = Loren.Signal({ Backlog = 0 }), -- no replay, as in 1.5.1
	},
}

return RoundService
```

To change the default for every signal, use `Loren.Configure({ Backlog = 0 })` on the server (clients get the value from the server).

There's a second queue on the server. A client can't receive anything until it says hello to the server, which it does during its boot. Loren calls this the handshake. Until then, reliable messages to that player wait on the server: up to 256 KiB or 4096 messages, for up to 120 seconds after they joined. Unreliable messages to that player are dropped. [How it works](../advanced/how-it-works.md#before-the-handshake-the-outbox) says what happens past those limits.

## Typed signals

Give a Signal types in the `Spec` and Loren checks the values when you fire, and sends fewer bytes:

```lua title="src/server/Services/CombatService.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)
local T = Loren.T

local CombatService = {
	Signals = { "Hit" },
	Spec = {
		Hit = Loren.Signal(T.string(64), T.u16),
	},
}

function CombatService:Damage(player: Player, weapon: string, amount: number)
	self.Signals.Hit:Fire(player, weapon, amount)
end

return CombatService
```

A value that doesn't fit errors at the `Fire` line. Here, an amount of 70000 doesn't fit in a `T.u16`:

```text
(LORENঌ) CombatService.Hit:Fire: arg 2 Range
```

The argument number counts from the first value after the player. See [Typed specs](./typed-specs.md) for every type.

## Unreliable signals

For state you resend often, like positions, an unreliable Signal uses Roblox's `UnreliableRemoteEvent`:

```lua
Spec = {
	Positions = Loren.Signal(T.array(T.Vector3, 50), { Unreliable = true }),
},
```

- Messages may be dropped or arrive out of order.
- A message can be at most 900 bytes. `Fire` errors above that.
- The arguments must be typed, without `T.Instance` or `T.any`. Otherwise the boot fails with `Unreliable and Coalesce members need typed Args without T.Instance or T.any`.
- `Ordered = true` makes the client drop a message that arrives after a newer one. The order resets after 1 second without messages.
- They aren't queued for players whose client hasn't said hello yet.

## Instances in signals

An Instance travels as a reference. If the client can't see it (it's in `ServerStorage`, or streamed out), it arrives as `nil`. With a typed `T.Instance(...)` argument, the whole message is dropped instead, and counted in `SignalsDropped`. Use `T.optional(T.Instance("BasePart"))` if `nil` is fine.

Loren sends at the end of the game frame, not at the `Fire` line. If you fire a Signal with an Instance and destroy that Instance in the same game frame, the client gets `nil`. Call `Loren.Flush()` after the `Fire` to send right away.

## Controller signals

A Controller can have `Signals` too. There they're local to the client: a way for Controllers to talk to each other. Nothing goes over the network.

```lua title="src/client/Controllers/MenuController.luau"
local MenuController = {
	Signals = { "Opened", "Closed" },
}

function MenuController:Open(name: string)
	self.Signals.Opened:Fire(name)
end

return MenuController
```

```lua title="src/client/Controllers/SoundController.luau"
local SoundController = {
	Dependencies = { "MenuController" },
}

function SoundController:LorenIgnite()
	self.Dependencies.MenuController.Signals.Opened:Connect(function(name)
		print("Menu opened:", name)
	end)
end

return SoundController
```

These have `Fire`, `Connect`, `Once`, `Wait`, `DisconnectAll` and `Destroy`. Loren only creates them when `Signals` is an array of names. If your Controller keeps its own signal objects in a `Signals` table, Loren leaves it alone, as 1.5.1 did.

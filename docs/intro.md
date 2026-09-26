---
title: Introduction
sidebar_label: Introduction
sidebar_position: 1
description: What Loren is, what a Service and a Controller look like, and what changed in 2.0.
---

# Introduction

Loren is a framework for Roblox games written in Luau. Server code goes in **Services**. Client code goes in
**Controllers**. Each module lists the modules it needs by name, and Loren loads them, sorts them and starts them in
order. When a Controller calls a Service, Loren carries the call over the network and hands you a
[Promise](https://eryn.io/roblox-lua-promise/) (an object that settles later with the result or an error).

It also comes with a CLI, `loren`, that sets up projects for Rojo, Argon or Studio's built-in Script Sync.

:::info[2.0 is in beta]
Install the beta with `npm i -g loren-framework@next`. Plain `npm i -g loren-framework` still installs 1.5.1 until
2.0 is stable. See [Installation](./getting-started/installation.md).
:::

## A Service and a Controller

Here's a small feature from start to finish: the server keeps points per player, and the client shows them.

```lua title="src/server/Services/PointsService.luau"
local PointsService = {
	Client = {},
	Signals = { "PointsChanged" },
}

local points: { [Player]: number } = {}

function PointsService:AddPoints(player: Player, amount: number)
	points[player] = (points[player] or 0) + amount
	self.Signals.PointsChanged:Fire(player, points[player])
end

function PointsService.Client:GetPoints(player: Player): number
	return points[player] or 0
end

return PointsService
```

```lua title="src/client/Controllers/HudController.luau"
local HudController = {
	Dependencies = { "PointsService" },
}

function HudController:LorenBurn()
	local Points = self.Dependencies.PointsService

	Points.Signals.PointsChanged:Connect(function(total)
		print("Points:", total)
	end)

	local ok, total = Points.Try:GetPoints()
	if ok then
		print("Starting with", total)
	end
end

return HudController
```

What's going on:

- Functions under `Client` are the ones clients can call. Loren passes the calling player as the first argument,
  taken from the connection, so a client can't pretend to be someone else.
- `Signals = { "PointsChanged" }` is all the setup a signal needs. The server fires it, the client connects to it.
- `AddPoints` is not under `Client`, so only server code can call it.
- `Dependencies = { "PointsService" }` gives the Controller a **proxy**, a stand-in object for the Service. Calling a
  method on it returns a Promise. `Try` waits for the answer and gives you `ok` plus the values.
- `LorenBurn` runs once everything has started. See [Lifecycle](./core-concepts/lifecycle.md) for the full order.

No RemoteEvents to create, no require paths to keep in sync.

## What 2.0 changes

Version 2.0 is mostly about the parts you don't see. The Service and Controller shape is the same as 1.5.1, so your
code runs unchanged. Upgrading a project is one command, `loren update`.

Under the hood:

- **Every packet is checked before your code runs.** Junk is dropped without a log line for each one. When
  something fails, you get an error code and an incident id instead of a silent timeout.
- **Messages go out in batches, once per game frame.** A 64-byte call costs about 76 bytes on the wire, about 12 bytes of
  overhead.
- **New tools:** `proxy.Try`, client-to-server events (`ClientEvents`), typed argument specs, `Loren.Reject` for
  errors players should see, `LorenExtinguish` for shutdown, and `Loren.Testing` for specs without a server.

We measured all of this in Roblox Studio:

| Test | Result |
|---|---|
| Exploiter bot, 48,190 garbage packets at about 2,400 a second | 0 accepted. Honest players: 1,206 of 1,206 calls OK. Server frame time unchanged (p99 6.1 ms), 0 server warnings. |
| The same attack on 1.5.1 | 47,364 warnings (about 142k a minute), a server frame about 3x slower, route ids stolen through the handshake RemoteFunction, 43 handler crashes from crafted packets. |
| Stress, 3 players at 60 calls a second each | 100% of calls OK, 0 lost or reordered signals, about 1.8 µs average handler cost, round trip p50 about 15 ms on one machine. |
| Test suite, with 1 and 3 players | 1,212 tests passed, 0 failed. |

The CLI's own suite (141 tests, run with Node) passes too, including real Rojo and Argon runs.

Loren can't check your game logic, though. It stops malformed packets, but a client can still call `BuyItem` with
arguments a normal player could send. Checking prices, cooldowns and ownership is your job.
[Security](./networking/security.md) covers what Loren does and doesn't do.

## Where to go next

- New to Loren: [Installation](./getting-started/installation.md), then
  [Create a project](./getting-started/new-project.md) and [Your first service](./getting-started/first-service.md).
- On 1.5.1: [Upgrading from 1.5.1](./getting-started/upgrading.md).
- Looking up a command: [CLI](./cli-reference.md).
- Something's off: [FAQ and troubleshooting](./faq.md).

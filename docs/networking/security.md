---
title: Security
sidebar_label: Security
sidebar_position: 6
description: What Loren protects you from, what it can't, and a checklist for your own Services.
---

Assume some players run their own code on their client. This page covers what that code can and can't do to a Loren game, what Loren checks for you, and what's still your job.

## What an exploiter can do

A modified client can:

- Call every Client method and fire every ClientEvent of every Service, with any arguments, as often as the rate limits allow.
- Skip your client code entirely. Nothing your Controllers check is a guarantee.
- Read everything the server sends it. That includes the manifest: the names of your networked Services and their members, argument types, timeouts and rate limits.
- Send raw bytes to Loren's remotes that no honest client would send.

## What it can't do

- **Call server-only code.** Only functions under `Client` are reachable. Other Service methods aren't in the manifest, so they have no route id (the number Loren uses to address a member) and there's nothing to call.
- **Pretend to be another player.** The `player` argument comes from the connection, not from the packet.
- **Get junk past the decoder.** Every packet is checked before your code runs. In our attack test (below), 0 of 48,190 junk packets were accepted.
- **Fill your server log.** Loren counts bad traffic instead of logging each packet.

## What Loren can't do for you

Loren stops traffic that's malformed. It can't tell whether a well-formed call is fair. If a normal player can send `Buy(7, 1)`, an exploiter can send it too, as fast as the rate limit allows. Prices, cooldowns, ownership, distance and anything else that decides the game have to be checked on the server, against the server's state.

## Three layers of checks

1. **[Typed specs](./typed-specs.md)**: types, ranges, lengths. Loren checks them before anything else runs.
2. **[Middleware](./middleware.md)**: may this player do this right now?
3. **The handler**: the game rules, with the real state.

```lua title="src/server/Services/ShopService.luau"
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)
local T = Loren.T

local PRICES: { [number]: number } = { [1] = 100, [2] = 250 }
local COOLDOWN = 0.5

local ShopService = {
	Dependencies = { "PointsService" },
	Client = {},
	Middleware = {},
	Spec = {
		-- Layer 1: itemId must be a whole number from 1 to 2.
		Buy = Loren.Method(T.int(1, 2), { RateLimit = { 2, 4 } }),
	},
}

local lastBuy: { [Player]: number } = {}

-- Layer 2: may this player buy right now?
function ShopService.Middleware.Buy(player: Player, _itemId: number)
	local last = lastBuy[player]
	if last and os.clock() - last < COOLDOWN then
		return false, "Slow down"
	end
	return true
end

-- Layer 3: the game rules, checked against the server's state.
function ShopService.Client:Buy(player: Player, itemId: number)
	local price = PRICES[itemId]
	local Points = self.Server.Dependencies.PointsService
	if Points:GetPoints(player) < price then
		return Loren.Reject("Not enough points")
	end
	lastBuy[player] = os.clock()
	return Points:AddPoints(player, -price)
end

function ShopService:LorenIgnite()
	Players.PlayerRemoving:Connect(function(player)
		lastBuy[player] = nil
	end)
end

return ShopService
```

## Remote spies

A remote spy shows two remotes, `ReplicatedStorage.LorenNet.Reliable` and `LorenNet.Unreliable`, carrying buffers. Reading them takes some work, but it's possible, and the manifest spells out your member names and types. Treat everything a client can see as public: don't put secrets in Service, method or signal names, middleware reasons, or `Loren.Reject` messages and data. Hiding a method doesn't protect it. Checking its arguments does.

## Budgets and rate limits

Every player has budgets, checked before anything is decoded. These are the defaults:

| Budget, per player | Default |
| :--- | :--- |
| Frames, per remote | 120 a second, bursts of 140 |
| Bytes, both remotes | 128 KiB a second, bursts of 256 KiB |
| Messages | 600 a second |
| Calls, per method | 50 a second, bursts of 100 |
| Reliable events, per event | 75 a second, bursts of 150 |
| Unreliable events, per event | 120 a second, bursts of 60 |
| Calls yielded in handlers | 32 running, 64 more queued |

- A frame (one remote fire) over the frame, byte or message budget is dropped whole. The client is told, and the calls in that frame reject `RateLimited`.
- A call over its method's limit gets `RateLimited`: at most one such reply per method per player per second, the rest are dropped silently.
- An event over its limit is dropped.

Clients know these numbers and hold themselves to 90% of them, so an honest client stays under the server's limits. The [Limits](../advanced/limits.md) page has the full list and how to change them.

## Violations

Some packets can only come from a modified client: a frame (one remote fire) that isn't a buffer, a broken header, a route id that doesn't exist, a call before the client said hello, a reused call id, bytes that don't decode. Loren calls these violations. The frame is dropped, nothing is sent back, and the player's violation score goes up:

| Kinds | Weight | What happened |
| :--- | :---: | :--- |
| `Envelope`, `ExtraArgs`, `FrameSize`, `Refs`, `Framing`, `BadOp` | 10 | The frame itself is malformed. |
| `Route`, `BeforeHello`, `RepeatHello`, `DuplicateCall` | 5 | A message for a route that doesn't exist, sent too early, or with a call id already in use. |
| `Payload`, `Sidecar` | 2 | The arguments don't decode. |

The score drops by 1 point a second. Loren's own client never sends these.

Values that decode fine but break the rules, like NaN or a string over its max length, aren't violations. A call gets `BadRequest` (at most 16 of those replies per player per second), and an event is dropped.

### OnViolation

```lua title="src/server/Server.server.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

Loren.AddServices(script.Parent.Services)

Loren.OnViolation(function(player: Player, kind: string, score: number, counts: { [string]: number })
	print(player.Name, "sent bad traffic:", kind, "score", score)
	for name, n in counts do
		print("  ", name, n)
	end
end)

Loren.SetOnFire():expect()
```

- Server-only. You can add it at any time.
- It's called at most once per player per second. `counts` holds every kind since the last call, like `{ Framing = 3 }`, and `kind` is the most recent one.
- It runs in its own thread. An error in it is logged and doesn't affect Loren.

### KickScore

Kicking is off by default. `Loren.Configure({ KickScore = 100 })` kicks a player once their score reaches 100, with the message `(LORENঌ) Disconnected: invalid network traffic`. Watch `OnViolation` in your live game for a while before you pick a number.

## Logs

Loren never logs per bad packet. It keeps counters and prints at most one summary line per player every 30 seconds:

```text
(LORENঌ) uid=<user id> last 30s: <drops>; violations <kinds> (score <n>)
```

All Loren warnings also share a budget of 10 lines a minute. `Loren.GetStats()` has the running totals: `Violations`, `FramesDropped`, `CallsRateLimited`, `BadRequests`, `Busy` and more.

## Errors don't leak

When a handler throws, the client gets `(LORENঌ) InternalError [a1b2c3d4]`. The server logs the error and traceback under the same id. `ForwardErrors` decides whether the error text also goes to the client:

| `ForwardErrors` | Error text sent to the client |
| :--- | :--- |
| `"Studio"` (default) | Only when testing in Studio. |
| `"Never"` | Never. |
| `"Always"` | Always. The boot warns you, since live players would see your server errors. |

To send errors to your own tracker, use `Loren.OnError`. It gets `Service`, `Member`, `Player`, `Incident`, `Message` and `Traceback`, up to 10 times a second:

```lua
Loren.OnError(function(info)
	warn("[" .. info.Incident .. "]", info.Service .. "." .. info.Member, info.Message)
end)
```

For failures you mean, like "not enough points", return `Loren.Reject("Not enough points")`. That message goes to the client as it is.

## The attack test

We pointed an exploiter bot at a Studio test server. It fired 48,190 garbage packets, about 2,400 a second, while honest players kept playing. Then we ran the same attack against 1.5.1.

| What we checked | 1.5.1 | 2.0 |
| :--- | :--- | :--- |
| Junk reaching your handlers | Crafted packets got through: 43 handler crashes | None. 0 of 48,190 accepted |
| Server warnings | 47,364, about 142k a minute | 0 |
| Server frame time | About 3x slower | Unchanged, p99 6.1 ms |
| Route ids | Stolen through the handshake RemoteFunction | No RemoteFunction to ask |
| Honest players' calls | 83% OK (the test ran above 1.5.1's 50 calls/s cap) | 1,206 of 1,206 OK |

## Checklist

- Every Client method and ClientEvent checks its arguments, with a spec, middleware or the handler.
- Game rules are checked on the server, against server state. Never trust a price, position or timestamp from the client.
- Middleware uses the dot style, and `loren doctor` reports no issues.
- Middleware returns `true` to allow, and nothing else.
- Code only the server should run isn't under `Client`.
- Expected failures use `Loren.Reject`. `ForwardErrors` stays at `"Studio"`.
- Expensive methods have a tight `RateLimit`. Methods that read, yield and write player state are `Serial`.
- `OnViolation` and `OnError` report to your own logging.
- No secrets in names, middleware reasons or reject messages.

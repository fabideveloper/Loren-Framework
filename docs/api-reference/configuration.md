---
title: Configuration
sidebar_label: Configuration
sidebar_position: 2
description: Every Loren.Configure setting, its default, and what it changes.
---

```lua title="src/server/Server.server.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

Loren.Configure({
	DefaultTimeout = 15,
	ForwardErrors = "Never",
})

Loren.AddServices(script.Parent.Services)
Loren.SetOnFire():expect()
```

Every key has a default, so you only set what you want to change.

## How Configure works

- Call it before `SetOnFire`. After that, it raises an error.
- You can call it more than once. Each call merges its keys into the settings so far.
- Every key in a call is checked before any is applied. An unknown key, a wrong type or a value out of range raises an error at your line and changes nothing. A key with the wrong capitalization gets a suggestion.
- Numbers must be finite. `math.huge` and NaN are refused.
- Most keys are **server** keys. Set them in your server script. The server sends the limits clients need, so clients follow them without being told. A server key set on a client is ignored, with a warning in Studio.
- A few keys work on **both** sides and apply to the side that sets them. `PromiseTraces` is **client** only.

## Every key

### Rate limits (server)

Each player gets these budgets. Clients hold themselves to `MirrorFraction` of each one, so an honest client slows down on its own before the server would have to refuse anything. What happens when a limit is hit is on the [Security](../networking/security.md) page.

| Key | Default | Allowed | What it limits |
|---|---|---|---|
| `FrameRate` | 120 | a number above 0 | Remote fires per second from one player, per channel (reliable and unreliable each). |
| `FrameBurst` | 140 | a number, 1 or more | Remote fires a player can send in a quick burst. |
| `ByteRate` | 131072 | a number above 0 | Bytes per second from one player, both channels (128 KiB). |
| `ByteBurst` | 262144 | a number, 1 or more | Bytes in a quick burst (256 KiB). |
| `MessageRate` | 600 | a number above 0 | Calls and events per second from one player. |
| `MessageBurst` | 600 | a number, 1 or more | Calls and events in a quick burst. |
| `MethodRate` | 50 | a number above 0 | Calls per second to one Client method, per player. |
| `MethodBurst` | 100 | a number, 1 or more | Calls to one Client method in a quick burst. |
| `EventRate` | 75 | a number above 0 | Fires per second of one reliable ClientEvent, per player. |
| `EventBurst` | 150 | a number, 1 or more | The same, in a quick burst. |
| `UnreliableEventRate` | 120 | a number above 0 | Fires per second of one unreliable ClientEvent, per player. |
| `UnreliableEventBurst` | 60 | a number, 1 or more | The same, in a quick burst. |
| `MirrorFraction` | 0.9 | above 0, up to 1 | The share of each limit clients hold themselves to. |

Rates refill continuously. A burst is how many you can spend at once before the rate applies.

### Calls (server)

| Key | Default | Allowed | What it does |
|---|---|---|---|
| `DefaultTimeout` | 10 | 1 to 120 seconds, rounded to 0.1 | How long a client waits for a reply before `Timeout`, for methods without their own. |
| `MaxRunningCalls` | 32 | an integer, 1 or more | Calls per player whose handler yielded and is still running. |
| `MaxQueuedCalls` | 64 | an integer, 0 to 1024 | Calls per player waiting behind those. Past this, calls get `Busy`. |
| `MaxZombies` | 16 | an integer, 1 or more | Calls per player that passed their deadline while the handler kept running. Past this, methods holding one get `Busy`. |
| `MaxZombiesPerRoute` | 4 | an integer, 1 or more | The same, for one method. A method at this count gets `Busy`. |
| `SerialQueue` | 8 | an integer, 0 to 1024 | Calls per player waiting on one `Serial` method. |
| `MaxPending` | 256 | an integer, 1 to 4096 | Calls one client can have waiting for a reply. Past this, `TooManyInFlight`. |
| `WatchdogGrace` | 5 | 0 to 30 seconds | Once a call's timeout plus this has passed, the server stops tracking it and frees its slot. |
| `CancelOnTimeout` | `false` | a boolean | At that point, cancel the handler's thread instead of letting it run to the end. |

### Signals (server)

| Key | Default | Allowed | What it does |
|---|---|---|---|
| `Backlog` | 64 | an integer, 0 to 1024 | Messages kept per Signal on a client until its first `Connect`. `0` turns the backlog off, as in 1.5.1. |
| `BacklogWindow` | 10 | an integer, 0 to 255 seconds | How long after the client is ready it keeps backlogs for Signals nobody connected to. |

### Errors and safety (server)

| Key | Default | Allowed | What it does |
|---|---|---|---|
| `ForwardErrors` | `"Studio"` | `"Studio"`, `"Never"` or `"Always"` | When clients see the text of a server error. `"Studio"` sends it only in Studio. `"Always"` gets a boot warning. |
| `KickScore` | `false` | `false` or a number above 0 | Kick a player whose violation score reaches this number. Off by default. |
| `MiddlewareArityCheck` | `true` | a boolean | Look for colon-style middleware at boot. See [Middleware](../networking/middleware.md). |

### Boot (both sides)

| Key | Default | Allowed | What it does |
|---|---|---|---|
| `StrictCycles` | `false` | a boolean | A dependency cycle fails the boot. |
| `CycleWarnings` | `false` | a boolean | List allowed dependency cycles in the boot warnings. |
| `IgniteTimeout` | `false` | `false` or seconds above 0 | A `LorenIgnite` (setup hook) still running after this long fails the boot. With `false`, Loren only warns. |

### Encoding and debugging

| Key | Side | Default | Allowed | What it does |
|---|---|---|---|---|
| `InlineTables` | both | `true` | a boolean | `false` sends every table through Roblox's own remote serialization, as 1.5.1 did, instead of Loren's compact form. It costs more bytes. Use it to rule Loren's encoding out when you chase a bug. |
| `PromiseTraces` | client | `"Studio"` | `"Studio"`, `"Always"` or `"Never"` | Record where each call was made, so an unhandled rejection warning points at your line. `"Studio"` does it only in Studio. |

### Members (server)

`Members` overrides options for one Client method or ClientEvent, by `"Service.Member"` name:

| Override | Allowed | Applies to |
|---|---|---|
| `RateLimit` | `{ rate, burst }`, rate above 0, burst 1 or more | Methods and ClientEvents |
| `Timeout` | 1 to 120 seconds, rounded to 0.1 | Methods |
| `Serial` | a boolean | Methods |
| `CancelOnTimeout` | a boolean | Methods |
| `AllowNonFinite` | a boolean | Methods and ClientEvents |

An override that doesn't apply to the member's kind is ignored. `Members` never applies to Signals. A name that matches no Client method or ClientEvent is a boot warning, with a suggestion.

For each option, the first of these that sets it wins:

1. `Members["Service.Member"]`
2. the member's `Spec` (see [Typed specs](../networking/typed-specs.md))
3. your `Configure` default, like `MethodRate` or `DefaultTimeout`
4. Loren's default

## Checks at boot

When the server boots, it checks that clients can always get their largest message through:

- `ByteBurst * MirrorFraction` must be at least 131072. A client's heaviest single send costs about 70 KB against the byte budget.
- `FrameBurst * MirrorFraction` must be at least 1.
- `MessageBurst * MirrorFraction` must be at least 1.

If one fails, the boot fails and the report shows the number it got.

## Examples

A live game that keeps error text private, kicks clients that keep sending garbage, and won't hang on a stuck `LorenIgnite`:

```lua title="src/server/Server.server.luau"
Loren.Configure({
	ForwardErrors = "Never",
	KickScore = 100,
	IgniteTimeout = 15,
})
```

Each violation adds 2 to 10 points to a player's score, and the score drops by 1 point a second. Violations are packets an unmodified client doesn't send, so honest players shouldn't collect any.

Different limits for a few members:

```lua title="src/server/Server.server.luau"
Loren.Configure({
	Members = {
		["ShopService.Buy"] = { RateLimit = { 2, 5 }, Serial = true },
		["ReportService.Export"] = { Timeout = 60 },
		["CombatService.Aim"] = { RateLimit = { 30, 30 } },
	},
})
```

Client settings go in the client script:

```lua title="src/client/Client.client.luau"
Loren.Configure({
	PromiseTraces = "Always", -- point unhandled rejections at your line, outside Studio too
	StrictCycles = true, -- fail the client boot on a Controller cycle
})
```

---
title: Loren API
sidebar_label: Loren API
sidebar_position: 1
description: Every field and function on the Loren table, plus the proxy, signal and connection objects.
---

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)
```

`ReplicatedStorage.Shared.Loren` is a six-line shim. It finds the runtime (`LorenRuntime` next to it, or in `ReplicatedStorage`) and returns it. It's the same module on the server and the client.

These docs write `Loren.X(...)`. `Loren:X(...)` works too, so 1.5.1 code like `Loren:SetOnFire()` runs unchanged. Objects (proxies, signals, connections) use a colon: `Shop:Buy("Sword")`, `signal:Connect(fn)`.

Each entry below says which side it works on, when you can call it, and what it returns.

## Fields

| Field | Type | Meaning |
|---|---|---|
| `Loren.IsServer` | `boolean` | `RunService:IsServer()`. |
| `Loren.IsClient` | `boolean` | `not IsServer`. It's `false` in Studio's Run mode and in Edit mode, which run as a server. |
| `Loren.IsOnFire` | `boolean` | `true` once `SetOnFire` has been called. |
| `Loren.IsReady` | `boolean` | `true` once the boot has finished. |
| `Loren.State` | `string` | `"Idle"`, `"Booting"`, `"Ready"`, `"Failed"` or `"ShuttingDown"`. See [Lifecycle](../core-concepts/lifecycle.md#states). |
| `Loren.Version` | `string` | The runtime version, like `"2.0.0"`. |
| `Loren.Errors` | `{ [string]: string }` | Error code names, for comparing with `info.Code`. See [Errors](./errors.md). |
| `Loren.T` | table | The type catalog for specs. See [Typed specs](../networking/typed-specs.md). |
| `Loren.Testing` | table | `Mount`, `Fired`, `Emit`, `Reset`. See [Testing](../core-concepts/testing.md). |

## Boot and registration

### AddServices

`Loren.AddServices(container, options?)` · server · before `SetOnFire` · returns nothing

```lua
Loren.AddServices(script.Parent.Services)
Loren.AddServices(script.Parent.Services, { Recursive = true }) -- include sub-folders
Loren.AddServices({ moduleA, moduleB }) -- or an array of ModuleScripts
```

Registers every ModuleScript in `container`. Without `Recursive`, only direct children count. On a client it does nothing and warns in Studio. After `SetOnFire` it raises an error. See [Services](../core-concepts/services.md#registering-services).

### AddControllers

`Loren.AddControllers(container, options?)` · client · before `SetOnFire` · returns nothing

```lua
Loren.AddControllers(script.Parent.Controllers)
```

The same rules as `AddServices`, for Controllers. On the server it does nothing and warns in Studio.

### SetOnFire

`Loren.SetOnFire()` · both · any time · returns a Promise

```lua
Loren.SetOnFire():expect()
```

Starts the boot. The Promise resolves with `Loren` once everything runs, or rejects with the boot report. Later calls return a Promise for the same boot. See [Lifecycle](../core-concepts/lifecycle.md).

### OnReady

`Loren.OnReady()` · both · any time · returns a Promise

```lua
Loren.OnReady():andThen(function()
	print("Loren is running")
end)
```

Resolves with `Loren` when the boot finishes, right away if it already has. Rejects if the boot fails. Works before `SetOnFire` is called.

### Configure

`Loren.Configure(settings)` · both · before `SetOnFire` · returns nothing

```lua
Loren.Configure({ DefaultTimeout = 15, ForwardErrors = "Never" })
```

Merges settings. An unknown key or a bad value raises an error at your line and changes nothing. See [Configuration](./configuration.md) for every key.

## Finding modules

### GetService

`Loren.GetService(name)` · both · server: after `AddServices`; client: after `OnReady` · returns a table

```lua
local Points = Loren.GetService("PointsService")
```

On the server you get the Service's table. On the client you get its proxy, and calling it before the client has the manifest (the Service list from the server) raises an error that tells you to wait for `OnReady`. An unknown name raises an error with a suggestion.

### GetController

`Loren.GetController(name)` · client · after `AddControllers` · returns a table

```lua
local Hud = Loren.GetController("HudController")
```

Returns the Controller's table. Raises an error on the server.

### Get

`Loren.Get(module)` · both · after registration · returns the same table

```lua
local PointsService = Loren.Get(require(script.Parent.PointsService))
```

Returns `module` if it's a registered Service (server) or Controller (client), and raises an error if not. It keeps the module's type for the type checker. Use the dot form here; `Loren:Get(m)` runs but doesn't type-check.

## Server hooks

### AddMiddleware

`Loren.AddMiddleware(fn)` · server · before `SetOnFire` · returns nothing

```lua
local banned: { [number]: boolean } = {}

Loren.AddMiddleware(function(player: Player, info, ...)
	if banned[player.UserId] then
		return false, "You are banned"
	end
	return true
end)
```

Runs `fn(player, info, ...)` before every Client method call and ClientEvent, ahead of the member's own middleware. `info` is `{ Service, Member, Kind }`, where `Kind` is `"Method"` or `"Event"`. Only `true` lets the call through. See [Middleware](../networking/middleware.md).

### OnViolation

`Loren.OnViolation(fn)` · server · any time · returns nothing

```lua
Loren.OnViolation(function(player: Player, kind: string, score: number, counts)
	print(player.UserId, kind, score, counts[kind])
end)
```

Called when a client sends traffic an unmodified client never sends. `kind` is the latest violation's name, `score` is the player's current score, and `counts` maps each violation name to how often it happened since the last call. At most once per player per second. See [Security](../networking/security.md).

### OnError

`Loren.OnError(fn)` · server · any time · returns nothing

```lua
Loren.OnError(function(info)
	warn(info.Service, info.Member, info.Incident, info.Message)
end)
```

Called when a Client method's handler or middleware throws, or its return values can't be sent. `info` holds `Service`, `Member`, `Player`, `Incident`, `Message` and `Traceback`. Up to 10 calls per second across the server. See [Errors](./errors.md#onerror).

## Network

### Flush

`Loren.Flush()` · both · any time · returns nothing

```lua
self.Signals.Spawned:FireAll(part)
Loren.Flush()
part:Destroy()
```

Loren normally sends what you queued at the end of the game frame. `Flush` sends it now. Use it when you're about to destroy an Instance you sent in the same game frame; otherwise the client may get `nil` for it. On the client it sends only if the send budget allows (61 sends a second at most), otherwise in the next free slot. Before the network is up it does nothing.

### GetStats

`Loren.GetStats()` · both · any time · returns a table

```lua
local stats = Loren.GetStats()
print(stats.MessagesIn, stats.FramesDropped, stats.RunningCalls)
```

A fresh table of counters. All zeros before the boot. The fields are listed [below](#getstats-fields).

### DumpManifest

`Loren.DumpManifest()` · server · after the boot built the routes · returns a table

```lua
Loren.OnReady():andThen(function()
	for _, service in Loren.DumpManifest().services do
		print(service.name, #service.members)
	end
end)
```

A copy of what clients receive: `version`, `limits` and `services`. Each service has `name` and `members`; each member has `name`, `kind` (1 Method, 2 Event, 3 Signal), `route`, `timeout`, `rate`, `burst`, `backlog` and its typed `args` and `returns` if it has a Spec. Handy for checking what's exposed. Raises an error on the client or before the boot.

## Values and specs

### Reject

`Loren.Reject(message, data?)` · both · any time · returns a rejection value

```lua
function ShopService.Client:Buy(player: Player, item: string)
	return Loren.Reject("Not enough points", { need = 50 })
end
```

Return it (or throw it with `error(...)`) from a Client method to reject the caller's Promise on purpose. The client gets `message` (cut to 256 bytes) and `info.Data = data`. See [Errors](./errors.md#reject).

### Method, Event, Signal

`Loren.Method(...)`, `Loren.Event(...)`, `Loren.Signal(...)` · both · any time · return a spec

```lua
local T = Loren.T

local ShopService = {
	Client = {},
	ClientEvents = { "Browse" },
	Signals = { "Purchased" },
	Spec = {
		Buy = Loren.Method(T.string(32), T.int(1, 99), { Returns = { T.bool }, Timeout = 5 }),
		Browse = Loren.Event(T.string(32)),
		Purchased = Loren.Signal(T.string(32)),
	},
}

function ShopService.Client:Buy(player: Player, item: string, amount: number): boolean
	return true
end
```

Describe a member's arguments and options in the Service's `Spec`. The full option list and the `T` catalog are in [Typed specs](../networking/typed-specs.md).

## Testing

`Loren.Testing.Mount(module, options?)`, `Loren.Testing.Fired(signal)`, `Loren.Testing.Emit(event, player, ...)` and `Loren.Testing.Reset(options?)` work on both sides at any time. They're covered in [Testing](../core-concepts/testing.md).

## Service proxies

What a Controller gets for a networked Service, from `Dependencies` or `Loren.GetService`:

| Member | Returns |
|---|---|
| `proxy:Method(...)` | A Promise. It resolves with the handler's return values, or rejects with `(message, info)`. |
| `proxy.Try:Method(...)` | Yields, then returns `true, ...values` or `false, message, info`. |
| `proxy.Signals.Name` | A signal. See [Signals on the client](#signals-on-the-client). |
| `proxy.ClientEvents.Name` | An event you fire. See [ClientEvents on the client](#clientevents-on-the-client). |

```lua
local Shop = self.Dependencies.ShopService

Shop:Buy("Sword"):andThen(print):catch(warn)

local ok, item = Shop.Try:Buy("Sword")
```

An unknown name raises an error with a suggestion. A dot call with arguments raises an error. A dot call without arguments, `Shop.GetPrices()`, works as in 1.5.1. See [Calls and promises](../networking/calls.md).

## Signals on the server

`Service.Signals.Name` on the server:

| Method | Sends to |
|---|---|
| `:Fire(player, ...)` | One player. |
| `:FireAll(...)` | Every player. |
| `:FireFor(players, ...)` | Each player in the array. |
| `:FireExcept(playerOrPlayers, ...)` | Everyone except one player or an array of players. |

```lua
self.Signals.Scored:Fire(player, 10)
self.Signals.RoundStarted:FireAll("Desert")
self.Signals.TeamMessage:FireFor(game.Teams.Red:GetPlayers(), "Hold the flag")
self.Signals.Emoted:FireExcept(player, player, "wave")
```

A first argument that isn't a Player raises an error. So does a value the member's Spec rejects, and an unreliable message over 900 bytes. Firing at a player who already left does nothing (it's counted in `SignalsDropped`). `Connect`, `Once`, `Wait` and `DisconnectAll` raise an error here; they belong to the client. See [Signals](../networking/signals.md).

## Signals on the client

`proxy.Signals.Name` on the client:

| Method | Returns |
|---|---|
| `:Connect(fn)` | A connection. `fn` gets the values the server fired. |
| `:Once(fn)` | A connection that disconnects itself after one call. |
| `:Wait()` | Yields until the next fire, then returns its values. |
| `:DisconnectAll()` | Nothing. Disconnects every listener. |

```lua
local connection = Shop.Signals.Purchased:Connect(function(item: string)
	print("Purchased", item)
end)
```

Messages that arrive before the first `Connect`, `Once` or `Wait` are kept (up to 64 per signal) and replayed to it. `Fire`, `FireAll`, `FireFor` and `FireExcept` raise an error here.

## Local signals

A Controller's `Signals` names become local signals. They never leave the client.

| Method | Returns |
|---|---|
| `:Fire(...)` | Nothing. Calls every listener. |
| `:Connect(fn)`, `:Once(fn)` | A connection. |
| `:Wait()` | Yields until the next `Fire`, then returns its values. |
| `:DisconnectAll()`, `:Destroy()` | Nothing. Both disconnect every listener. |

```lua
self.Signals.ItemBought:Fire("Sword")
```

## ClientEvents on the server

`Service.ClientEvents.Name` on the server:

| Method | Returns |
|---|---|
| `:Connect(fn)` | A connection. `fn` gets `(player, ...)`. |
| `:Once(fn)` | A connection that disconnects itself after one call. |
| `:Wait()` | Yields, then returns `player, ...`. |
| `:DisconnectAll()` | Nothing. |

```lua
self.ClientEvents.Aim:Connect(function(player: Player, direction: any)
	if typeof(direction) ~= "Vector3" then
		return
	end
end)
```

A listener that errors is caught, and the other listeners still run. The error is logged at most once per event every 10 seconds, so a client can't flood your output. `Fire` raises an error here. See [Client events](../networking/client-events.md).

## ClientEvents on the client

`proxy.ClientEvents.Name` on the client has one method, `:Fire(...)`. It sends the values to the server and returns nothing; there's no reply. `Connect`, `Once` and `Wait` raise an error here.

```lua
local Combat = self.Dependencies.CombatService
Combat.ClientEvents.Aim:Fire(workspace.CurrentCamera.CFrame.LookVector)
```

## Connections

Every `Connect` and `Once` returns a connection:

| Member | Meaning |
|---|---|
| `Connected` | `true` until it's disconnected. |
| `Disconnect()` | Stops the listener. Works as `connection:Disconnect()` or `connection.Disconnect()`, and calling it twice is fine. |
| `Destroy()` | The same as `Disconnect`. |

Listeners run in the order they connected. One that yields doesn't hold up the others. A listener connected during a fire runs from the next fire. One disconnected during a fire is skipped.

## GetStats fields

| Field | Server | Client |
|---|---|---|
| `Side` | `"Server"` | `"Client"` |
| `FramesIn`, `FramesOut` | Remote fires received and sent. | The same. |
| `BytesIn`, `BytesOut` | Bytes received and sent. | The same. |
| `MessagesIn`, `MessagesOut` | Calls, events and replies inside those fires. | The same. |
| `FramesDropped` | Client fires refused for going over a rate limit. | Fires the server reported as refused. |
| `EventsLost` | 0 | Events the client dropped for its rate limit, or that were in refused fires. |
| `CallsRateLimited` | Calls rejected with `RateLimited`. | The same, seen from the client. |
| `BadRequests` | Calls rejected with `BadRequest`. | The same, seen from the client. |
| `Busy` | Calls rejected with `Busy`. | The same, seen from the client. |
| `Violations` | Violations recorded, all players. | 0 |
| `LateReplies` | 0 | Replies that arrived after their call timed out. |
| `OutboxDropped` | Messages dropped while a joining client wasn't connected yet. | Messages the server reported as dropped that way. |
| `SignalsDropped` | Signals to players who left, or unreliable signals sent before a client connected. | Signals with a missing Instance, or pushed out of a full backlog. |
| `RunningCalls` | Handler calls that yielded and are still running. | 0 |
| `ZombieCalls` | Calls past their deadline whose handler is still running. | 0 |
| `PendingCalls` | 0 | Calls waiting for a reply. |
| `Players` | Players Loren is tracking. | 0 |
| `Routes` | Network members of networked Services. | The same, from the client's view. |

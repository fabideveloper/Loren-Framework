---
title: Limits
sidebar_label: Limits
sidebar_position: 2
description: Every hard limit and default budget in Loren's networking, and how to change the ones you can.
---

Some limits are fixed by the wire format. Others are budgets with defaults you can change. Both are on this page.

## Fixed limits

| Limit | Value | Past it |
| :--- | :--- | :--- |
| Untyped arguments from a client | 20 | The call rejects with `BadArgument` before it's sent; an event `Fire` raises an error. |
| Untyped values to a client (signal arguments, return values) | 255 | A `Fire` raises an error; a reply fails with `BadResult`. |
| Typed fields in `Args` or `Returns` | 32 | Error where the spec is declared. |
| Nesting of untyped tables | 16 levels | `BadArgument` on the client, `BadRequest` on the server. |
| Untyped values in one client message | 2048 | `BadArgument`. |
| Values in copied (sidecar) tables, per client frame | 2048 | The client starts a new frame. More in one message: `BadArgument`. |
| Sidecar slots (Instances, CFrames, copied tables) per client frame | 255 | The client starts a new frame. More in one message: `BadArgument`. |
| One client message | 64 KiB | `PayloadTooLarge`; an event `Fire` raises an error. |
| Client reliable frame | 16 KiB | The next message starts a new frame. |
| Messages in one client frame | About 540 by default (`MessageBurst × MirrorFraction`, at most 1024) | The next message starts a new frame. The server treats more than 1024 as a violation. |
| Frame size the server accepts | 72 KiB reliable, 1000 bytes unreliable | Dropped as a violation. |
| Server frame | 64 KiB | A larger message goes alone. There's no cap from server to client. |
| Unreliable message | 900 bytes, header included | `Fire` raises an error. |
| Client sends | 61 a second | The next send waits for its slot. |
| Networked members (routes) | 65,535 | The boot fails. |
| Service, member, struct field and enum names | 255 bytes | The boot fails, or an error where the type is declared. |
| `Loren.Reject` and middleware messages | 256 bytes | Cut to 256 bytes. |
| Method timeout | 1 to 120 seconds | Error where it's set. |
| Signal backlog | 0 to 1024 messages | Error where it's set. |
| `T.string`, `T.buffer`, `T.array`, `T.map` | 1024 unless you set a max | `BadRequest` on the server, `BadArgument` or an error on the sender. |
| `T.enum` names, `T.struct` fields | 1 to 255 | Error where the type is declared. |
| Nesting of `T` types | 16 levels | Error where the type is declared. |
| Outbox before the client says hello (the handshake) | 256 KiB or 4096 messages | Newer messages are dropped, and Loren warns once. |
| How long the outbox waits for hello | 120 seconds after joining | The whole outbox is dropped, and so is every later reliable message until the client says hello. |
| Hellos from one client | One every 5 seconds | A violation. |
| `Ordered` sequence | Resets after 1 second of silence | |
| Timed-out call ids | Held for at least 60 seconds | A late reply is recognized and dropped. |
| Loren warnings | 10 lines a minute in total, 1 summary per player per 30 seconds | Suppressed and counted. |
| Replies to refused calls | 1 `RateLimited` per method per player per second, 16 `BadRequest` per player per second | Extra calls get no reply and time out. |
| `OnViolation` | Once per player per second | Counts add up until the next call. |
| `OnError` | 10 calls a second | Extra ones are skipped. |

## Default budgets

Each budget has a burst and a rate. The burst is how many you can send at once. The rate is how fast that allowance refills, per second. The client gets these numbers in the manifest and holds itself to 90% of them (`MirrorFraction`), so an honest client stays under the server's limits.

| Key | Default | Counted per | What it limits |
| :--- | :--- | :--- | :--- |
| `FrameRate` / `FrameBurst` | 120 / 140 | player, per remote | Frames a second. |
| `ByteRate` / `ByteBurst` | 131072 / 262144 | player | Bytes a second (128 KiB, bursts of 256 KiB), both remotes. |
| `MessageRate` / `MessageBurst` | 600 / 600 | player | Messages a second. |
| `MethodRate` / `MethodBurst` | 50 / 100 | player, per method | Calls. |
| `EventRate` / `EventBurst` | 75 / 150 | player, per reliable event | Reliable ClientEvent fires. |
| `UnreliableEventRate` / `UnreliableEventBurst` | 120 / 60 | player, per unreliable event | Unreliable ClientEvent fires. |
| `MirrorFraction` | 0.9 | client | How close to the limits clients go. |
| `MaxRunningCalls` | 32 | player | Calls yielded inside handlers at once. |
| `MaxQueuedCalls` | 64 | player | Calls waiting behind those. Past it: `Busy`. |
| `MaxZombies` / `MaxZombiesPerRoute` | 16 / 4 | player / player and method | Timed-out handlers still running. |
| `SerialQueue` | 8 | player, per `Serial` method | Calls waiting in line. Past it: `Busy`. |
| `MaxPending` | 256 | client | Calls waiting for a reply. Past it: `TooManyInFlight`. |
| `DefaultTimeout` | 10 | method | Seconds before a call rejects with `Timeout`. |
| `WatchdogGrace` | 5 | method | Seconds after the timeout before the server gives up on a call. |
| `CancelOnTimeout` | false | method | Whether the server cancels the handler when it gives up. |
| `Backlog` | 64 | signal | Messages kept for a late first `Connect`. |
| `BacklogWindow` | 10 | client | Seconds after the client boot that backlogs are kept. |

A frame costs `max(bytes, 64)`, plus 16 per sidecar slot, plus 8 for every value inside copied tables and the length of their strings. That's what's charged against the byte budget.

## Changing them

Every key above is set on the server, before `SetOnFire`:

```lua title="src/server/Server.server.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

Loren.Configure({
	MethodRate = 100,
	MethodBurst = 200,
	DefaultTimeout = 15,
	Members = {
		["ShopService.Buy"] = { RateLimit = { 2, 4 }, Timeout = 5 },
		["AimService.Aim"] = { RateLimit = { 30, 30 } },
	},
})

Loren.AddServices(script.Parent.Services)
Loren.SetOnFire():expect()
```

- Clients get the values from the server. Setting a server-only key on the client does nothing, and Studio warns.
- `Members` changes one method or ClientEvent. Its keys are `RateLimit`, `Timeout`, `Serial`, `CancelOnTimeout` and `AllowNonFinite`. The same options can go in the Service's `Spec` (see [Typed specs](../networking/typed-specs.md#options)); `Members` wins when both are set. `Members` never applies to Signals. A Signal's options come from its `Spec`, and `Backlog` falls back to `Configure`'s `Backlog`.
- A bad key or value errors at the `Configure` line, with a suggestion for typos.

The boot also checks that the budgets leave room for the largest frame an honest client can send: `ByteBurst × MirrorFraction` has to be at least 131072, and `FrameBurst × MirrorFraction` and `MessageBurst × MirrorFraction` at least 1. If not, the boot fails and says which one.

The [Configuration](../api-reference/configuration.md) page has every `Configure` key with its allowed values.

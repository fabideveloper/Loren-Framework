---
title: How it works
sidebar_label: How it works
sidebar_position: 1
description: The remotes, the handshake, batching and the byte format behind Loren's networking, in plain words.
---

You don't need this page to use Loren. It's for when you want to know what goes over the wire, you're reading a remote spy, or you're chasing a timing issue.

## Two remotes

When the server boots, Loren creates a folder, `ReplicatedStorage.LorenNet`, with two attributes: `State` (`Booting`, `Ready`, `Failed` or `ShuttingDown`) and `Proto` (`2`). Inside it are two remotes:

- `Reliable`, a `RemoteEvent`.
- `Unreliable`, an `UnreliableRemoteEvent`.

Every Service shares these two. The remotes only show up once the server boot has finished and `State` is `Ready`. There's no RemoteFunction, and 1.5.1's `LorenBridge` and `LorenHandshake` are gone. Your own RemoteEvents keep working next to Loren's.

## The handshake

1. The client waits for `LorenNet.State` to be `Ready`. It warns after 60 seconds and keeps waiting.
2. It connects its listeners, then sends a short HELLO message.
3. The server answers with the manifest: every networked Service (one with a Client method, ClientEvent or Signal), each member's route number, options and types, and the budgets clients should hold themselves to. It's built once at boot.
4. The client builds the proxies from it. Then each Controller's `LorenIgnite` (setup) runs.

Everything in the manifest is visible to players. Server-only methods, the `root` of a `T.Instance` and `KickScore` are never in it. To see what your game exposes, dump it on the server:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

Loren.OnReady():andThen(function()
	local manifest = Loren.DumpManifest()
	for _, service in manifest.services do
		print(service.name, #service.members, "members")
	end
end)
```

## Routes

At boot every networked member gets a number, its route. The numbering is sorted, so the same code gives the same numbers on every server. Routes 1 to 223 take 1 byte in a message, up to 4063 take 2, and up to 65,535 take 3. Unreliable events and signals are numbered first, then reliable events, then signals, then methods, so the busiest kinds get the 1-byte ids. More than 65,535 members fails the boot.

## Batching

Loren doesn't fire a remote for every call or signal. It packs everything going to one player into one buffer and fires that once. These docs call one such fire a **frame**. That's what `FrameRate`, `FramesIn` and the frame budget count. It isn't the same as a game frame (one `Heartbeat`).

When frames go out:

- **The server** sends once per `Heartbeat`: usually one fire per player per remote that has something queued, more only when a frame fills up.
- **The client** sends at most 61 times a second, whatever its frame rate.
- That adds at most one Heartbeat of delay on the server, and at most 1/61 of a second on the client.
- `Loren.Flush()` sends now. On the client it still respects the 61-a-second limit, so it may wait for the next slot.

A client frame closes at 16 KiB and the next message starts a new one (a single larger message, up to 64 KiB, goes alone). Server frames close at 64 KiB, and a larger message goes alone. An unreliable fire is at most 900 bytes.

## What a frame looks like

A frame from a client starts with a 5-byte header: a sequence number (2 bytes), the message count (2 bytes) and the number of sidecar values (1 byte, see below). Then the messages, each one a length, a route id and a body. A frame from the server is messages back to back, with no header and no lengths.

| Message | Body |
| :--- | :--- |
| Call | Route, call id (2 bytes), arguments |
| Event, Signal | Route, a 2-byte sequence number if `Ordered`, arguments |
| OK | Call id, return values |
| ERR | Call id, error code, flags, then the message text, data and incident id when present |
| NOTICE | Tells the client about dropped frames, a server shutdown, or messages lost before its handshake |
| HELLO, MANIFEST | The handshake |

Typed arguments are written back to back with no tags. Untyped arguments are a count byte, then one tagged value each. Whole numbers from 0 to 127 fit in a single byte, tag included.

Here's `Shop:Buy(7, 2)`, untyped, if `Buy` is route 5 and this is call id 1:

```text
06        message length: 6 bytes follow
05        route 5
01 00     call id 1
02        2 arguments
87 82     the numbers 7 and 2, one byte each
```

That's 7 bytes. Alone in a frame, the header (`00 00 01 00 00`: sequence 0, 1 message, 0 sidecar values) makes it 12. Measured with Loren's byte counter, a call with 64 bytes of arguments costs about 76 bytes, so about 12 bytes of overhead.

## Inline values and the sidecar

Loren writes most values into its buffer itself: `nil`, booleans, numbers, strings, buffers, `Vector3`, `Vector2`, `Color3`, plain arrays and string-keyed tables. The rest ride in a "sidecar": a table passed as the second argument of the same `FireServer` or `FireClient` call, which Roblox serializes as usual. That's Instances, `CFrame`, `EnumItem`, `UDim2` and other Roblox types, plus tables Loren can't write inline (mixed keys, holes, non-string keys, a metatable). The buffer holds a reference to the sidecar slot.

The server checks a client's sidecar before it reads a single message: only tables and Roblox values, nothing deeper than 16 levels, keys that are strings, booleans or finite numbers, at most 2048 values and 255 slots per frame. Every value in it is charged 8 bytes against the player's byte budget, plus the length of its strings.

## Ordering

- For each player, reliable messages arrive in the order they were sent, and the server starts calls in that order. A handler that yields lets later calls run in the meantime. Use `Serial` when one call must finish before the next starts.
- There's no order between the reliable and the unreliable remote, between Loren and your own remotes, or between Loren and property replication.
- Loren sends at the end of the game frame. A RemoteEvent you fire after a Loren call in the same game frame may arrive first, and an Instance destroyed before the flush arrives as `nil`. Call `Loren.Flush()` when that matters.
- Tables are copied when you call or fire, so later changes don't affect what's sent.

## Before the handshake: the outbox

A player who just joined can't receive Loren messages until their client sends HELLO. Reliable messages fired to them wait on the server, up to 256 KiB or 4096 messages, for up to 120 seconds after they joined. Unreliable messages are dropped.

- **Over the size cap**, newer messages are dropped and Loren warns once.
- **After 120 seconds** without HELLO, the whole outbox is dropped, and so is every later reliable message until HELLO arrives.

Both count in `Loren.GetStats().OutboxDropped`. When HELLO arrives, the manifest goes first, then everything that waited, in order. On the client, signals then wait in their [backlog](../networking/signals.md#messages-sent-before-you-connect) until your code connects.

## What the server does with a frame

1. **Envelope.** The frame is a buffer between 5 bytes and 72 KiB (1000 bytes on the unreliable remote). Only the sidecar table may come with it, nothing else.
2. **Budgets.** The player's budgets for frames (remote fires), bytes and messages, all or nothing. A refused frame is reported back to the client, and its calls reject `RateLimited`.
3. **Sidecar.** The checks above.
4. **Each message.** The route exists and belongs on this remote, its rate limit, the call caps, then the arguments are decoded and checked.
5. **Dispatch.** Middleware, then your handler or listeners.

Anything malformed ends the frame and counts as a [violation](../networking/security.md#violations). Nothing is logged per packet, and one `pcall` around the whole parse catches anything unexpected.

## Memory and stats

Loren tags its own work with the memory category `Loren`, so you can find it in the Developer Console's memory view. `Loren.GetStats()` returns a fresh table of counters on either side. [Loren API](../api-reference/loren.md#getstats-fields) lists every field.

```lua
local stats = Loren.GetStats()
print(stats.Side, stats.MessagesOut, "messages sent,", stats.BytesOut, "bytes")
```

## Measured

In a Studio stress run with 3 players, each making 60 calls a second, every call came back OK, with 0 lost or reordered signals. The average handler cost was about 1.8 µs, and the round trip p50 was about 15 ms, all on one machine.

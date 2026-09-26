---
title: Typed specs
sidebar_label: Typed specs
sidebar_position: 5
description: Tell Loren the argument types of a method, event or signal. It checks them on both sides and sends fewer bytes.
---

A Spec is optional. Without one, arguments are untyped: any value goes, within the general rules on the [Calls](./calls.md#what-you-can-send) page. Add a `Spec` if you want Loren to check argument types for you. The packets get smaller too.

## A Spec

```lua title="src/server/Services/ShopService.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)
local T = Loren.T

local stock: { [number]: number } = { [1] = 10, [2] = 5 }

local ShopService = {
	Client = {},
	ClientEvents = { "Browse" },
	Signals = { "Sold" },
	Spec = {
		Buy = Loren.Method(T.u16, T.int(1, 99), {
			Returns = { T.bool },
			RateLimit = { 2, 4 },
		}),
		Browse = Loren.Event(T.enum({ "Weapons", "Armor", "Potions" })),
		Sold = Loren.Signal(T.string(32), T.u16),
	},
}

function ShopService.Client:Buy(player: Player, itemId: number, amount: number): boolean
	-- itemId is an integer from 0 to 65535, amount one from 1 to 99. Loren checked both.
	local left = stock[itemId]
	if left == nil or left < amount then
		return false
	end
	stock[itemId] = left - amount
	self.Server.Signals.Sold:FireAll(player.Name, itemId)
	return true
end

function ShopService:LorenIgnite()
	self.ClientEvents.Browse:Connect(function(player: Player, category: string)
		print(player.Name, "is looking at", category)
	end)
end

return ShopService
```

How it fits together:

- `Spec` is keyed by member name. Use `Loren.Method` for a Client method, `Loren.Event` for a ClientEvent and `Loren.Signal` for a Signal. The wrong one fails the boot: `ShopService.Spec.Buy is a Loren.Event but Buy is a Client method`.
- A key that matches no member is ignored with a boot warning.
- The `T` types come first, one per argument, in order. A plain table at the end holds the options.
- You can also pass the types as an option: `Loren.Method({ Args = { T.u16, T.int(1, 99) } })`. Not both.
- No types at all means untyped arguments. `Loren.Method({ Timeout = 30 })` only sets options.

## What you get

**The server checks every value** before middleware and before your handler. A call with a value that doesn't fit is refused and the handler never runs:

```text
(LORENঌ) BadRequest: arg 2 (Range)
```

An event that doesn't fit is dropped. Floats also have to be finite: NaN and infinity are refused unless you set `AllowNonFinite`.

**The sender checks too.** An honest client never sends a value the server would refuse:

- A call with a bad value rejects right away with `BadArgument`, with the same argument number and reason. It's never sent.
- `ClientEvents.X:Fire(...)` and `Signals.X:Fire(...)` with a bad value raise an error at your line, like `(LORENঌ) ShopService.Sold:Fire: arg 2 Range`.
- Return values that don't match `Returns` fail the call with `BadResult`, and the server logs it with an incident id.

**The packets get smaller.** Typed values carry no type tag. A `T.u16` is 2 bytes where an untyped 300 is 3, and a `T.Vector3` is 12 bytes where an untyped one is 13. The more fields, the more it adds up.

Specs are checks at run time. They don't change the Luau types your editor sees, so keep annotating your handler parameters.

## Options

| Option | Method | Event | Signal | What it does |
| :--- | :---: | :---: | :---: | :--- |
| `Args` | yes | yes | yes | The argument types as a table, instead of listing them first. |
| `Returns` | yes | | | The return value types. |
| `Timeout` | yes | | | Seconds, 1 to 120. The default is 10. |
| `RateLimit` | yes | yes | | `{ rate, burst }` per player. |
| `Serial` | yes | | | One call at a time per player, in order. |
| `CancelOnTimeout` | yes | | | Stop the handler thread when the server gives up on the call. |
| `AllowNonFinite` | yes | yes | yes | Let NaN and infinity through. |
| `Unreliable` | | yes | yes | Use the `UnreliableRemoteEvent`: may drop, 900 bytes per message. |
| `Ordered` | | yes | yes | Drop messages older than the last one received. Needs `Unreliable`. |
| `Coalesce` | | yes | | Keep only the latest `Fire` per client send. On by default for unreliable events. |
| `Backlog` | | | yes | Messages kept for a late first `Connect`, 0 to 1024. The default is 64. |

An unknown option is an error that lists the valid ones. [Calls](./calls.md#options-per-method), [Client events](./client-events.md) and [Signals](./signals.md) explain each option in context.

When a setting comes from more than one place, `Loren.Configure({ Members = ... })` wins over the `Spec`, which wins over the `Configure` defaults. `Members` never applies to Signals. A Signal's options come from its `Spec`, and `Backlog` falls back to `Configure`'s `Backlog`.

## The T catalog

`T` is `Loren.T`. Types marked "(refine)" can be called to narrow them, like `T.u8(1, 10)`. A name that doesn't exist errors with a suggestion: `T.U8` asks "Did you mean 'u8'?".

### Numbers

| Type | Bytes | Accepts |
| :--- | :--- | :--- |
| `T.u8`, `T.u16`, `T.u32` | 1, 2, 4 | Whole numbers from 0 up to 255, 65,535, 4,294,967,295. (refine) `T.u8(1, 10)` |
| `T.i8`, `T.i16`, `T.i32` | 1, 2, 4 | Signed whole numbers. (refine) `T.i16(-100, 100)` |
| `T.int(lo, hi)` | 1, 2 or 4 | Whole numbers from lo to hi, in the smallest type that holds them. |
| `T.f32`, `T.f64` | 4, 8 | Finite numbers. `T.f32` keeps float32 precision. (refine) `T.f32(0, 1)` |
| `T.num(lo, hi)` | 8 | A finite number from lo to hi. Both bounds are required. |
| `T.bool` or `T.boolean` | 1 | `true` or `false`. |

### Text and bytes

| Type | Bytes | Accepts |
| :--- | :--- | :--- |
| `T.string` | length + text | Valid UTF-8, up to 1024 bytes. (refine) `T.string(64)` sets the max; `T.string(64, { Binary = true })` skips the UTF-8 check. |
| `T.buffer` | length + data | A buffer up to 1024 bytes. (refine) `T.buffer(4096)` |

The length prefix is 1 byte when the max is 255 or less, 2 bytes up to 65,535, else 4.

### Roblox types

| Type | Bytes | Accepts |
| :--- | :--- | :--- |
| `T.Vector3`, `T.Vector2` | 12, 8 | Finite components. (refine) `T.Vector3(50)` also caps the length (magnitude) at 50. |
| `T.Color3` | 12 | A Color3. |
| `T.CFrame` | 48 | A CFrame, all 12 components, nothing lost. |
| `T.EnumItem(Enum.Material)` | 2 | An item of that Enum. |
| `T.Instance(className, root)` | a reference | An Instance that `IsA(className)`. Both arguments are optional. With a `root`, it must be a descendant of `root`; the server checks that, and the root never leaves the server. |

A `T.Instance` that arrives as `nil` (the receiver can't see it) is refused: a call gets `BadRequest`, a signal to a client is dropped, and a reply rejects with `MissingInstance`. Wrap it in `T.optional` to accept `nil`.

### Choices and containers

| Type | Bytes | Accepts |
| :--- | :--- | :--- |
| `T.enum({ "Red", "Green" })` | 1 | One of these strings (1 to 255 of them). |
| `T.optional(t)` | 1 + t | `t` or `nil`. |
| `T.array(t, max)` | count + items | A plain array of `t`, up to `max` items (1024 if you leave it out). |
| `T.map(k, v, max)` | count + pairs | A table from `k` to `v`, up to `max` pairs (1024 by default). Keys can be `T.bool`, a number type, `T.string`, `T.enum` or `T.EnumItem`. |
| `T.struct({ name = t, ... })` | the fields | A table with these fields, 1 to 255 of them. Other keys are ignored and not sent; a missing field fails unless it's `T.optional`. |
| `T.any` | one untyped value | Anything an untyped argument accepts. |

Types nest, up to 16 levels:

```lua
Spec = {
	SaveLoadout = Loren.Method(T.struct({
		name = T.string(32),
		slots = T.array(T.u16, 8),
		color = T.optional(T.Color3),
	})),
},
```

## Unreliable and coalesced members

Unreliable and coalesced members need typed arguments, and they can't use `T.Instance` or `T.any`. Those two sometimes hand their value to Roblox's own serialization, and these messages can't do that. They have to fit entirely in Loren's buffer. Anything else fails the boot:

```text
AimService.Aim: Unreliable and Coalesce members need typed Args without T.Instance or T.any
```

See [Client events](./client-events.md#reliable-or-unreliable) and [Signals](./signals.md#unreliable-signals).

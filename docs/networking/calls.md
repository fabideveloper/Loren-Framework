---
title: Calls and promises
sidebar_label: Calls and promises
sidebar_position: 1
description: How a Controller calls a Service method, what comes back, and what happens when a call fails.
---

A Controller calls a Service through a proxy (a client-side stand-in for the Service) and gets a Promise back. Here's one call, both sides:

## A call, start to finish

```lua title="src/server/Services/ShopService.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

local PRICES: { [string]: number } = { Sword = 100, Shield = 75 }

local ShopService = {
	Dependencies = { "PointsService" },
	Client = {},
}

function ShopService.Client:Buy(player: Player, item: string)
	local price = PRICES[item]
	if price == nil then
		return Loren.Reject("Unknown item")
	end
	local Points = self.Server.Dependencies.PointsService
	if Points:GetPoints(player) < price then
		return Loren.Reject("Not enough points")
	end
	return Points:AddPoints(player, -price)
end

return ShopService
```

```lua title="src/client/Controllers/ShopController.luau"
local ShopController = {
	Dependencies = { "ShopService" },
}

function ShopController:LorenBurn()
	local Shop = self.Dependencies.ShopService

	Shop:Buy("Sword")
		:andThen(function(pointsLeft)
			print("Bought a sword. Points left:", pointsLeft)
		end)
		:catch(function(message, info)
			warn("Buy failed:", message, info.Code)
		end)
end

return ShopController
```

What's going on:

- Only functions under `Client` can be called from a client. `PointsService:AddPoints` is a plain server method, so clients can't call it. It isn't even in the manifest, the list of members the server sends to clients.
- The client sends `"Sword"`. Loren fills in `player` from the connection, so a client can't pretend to be someone else.
- Inside a Client method, `self` is the `Client` table and `self.Server` is the Service.
- On the client, `self.Dependencies.ShopService` is a proxy. Every Client method on it returns a Promise.
- A Client method can't be named `Server`, `Signals`, `ClientEvents`, `Properties` or `Try`. Those names are skipped with a boot warning.

## Call with a colon

Write `Shop:Buy("Sword")`. A dot call with arguments raises an error at your line, because it would shift every argument by one:

```text
(LORENঌ) Call ShopService:Buy(...) with ':' (a '.' call shifts every argument)
```

The 1.5.1 form with no arguments, `Shop.GetStock()`, still works. A name that doesn't exist also errors at your line, with a suggestion:

```text
(LORENঌ) ShopService has no method 'Biy'. Did you mean 'Buy'? Members: Buy
```

## What comes back

A call returns a Promise from evaera's Promise library, which ships with Loren (`ReplicatedStorage.LorenPackages.Promise`). You get the usual methods: `andThen`, `catch`, `finally`, `await` and `expect`.

- It resolves with everything the handler returned, nils included. `return 1, nil, 3` arrives as `1, nil, 3`.
- If the handler returns a Promise, Loren waits for it and sends what it resolves with.
- `return false, "reason"` still resolves, the way it did in 1.5.1. The client gets `false, "reason"` in `andThen`. To make the call fail on purpose, return (or throw) `Loren.Reject(message, data)`.
- If the handler throws, the call rejects with `(LORENঌ) InternalError [a1b2c3d4]`. The server log has the error and traceback under the same id. In Studio the error text is added to the message; in a live game it isn't (see `ForwardErrors` on the [Security](./security.md#errors-dont-leak) page).

`Loren.Reject` can carry data along with the message:

```lua
return Loren.Reject("Not enough points", { need = price })
```

```lua
Shop:Buy("Sword"):catch(function(message, info)
	print(message, info.Data.need) -- "Not enough points", 100
end)
```

Always attach a `catch` (or use `Try` below). A rejected Promise with no handler prints the Promise library's "unhandled rejection" warning.

## Try: no Promise

`proxy.Try:Method(...)` waits for the reply and hands you the values directly:

```lua
local ok, result, info = Shop.Try:Buy("Sword")
if ok then
	print("Points left:", result)
else
	warn("Buy failed:", result, info.Code) -- on failure, result is the message
end
```

It returns `true, ...values` on success and `false, message, info` on failure. `Try` yields, so call it from code that can yield: `LorenBurn`, a `task.spawn`, an event handler. Don't call it in `LorenIgnite`, which must not yield. Calling it where yielding isn't allowed raises an error.

## When a call fails

Every failure hands you two values: a `message` string and an `info` table. The message is a plain string, so 1.5.1 code that compares it with `"(LORENঌ) Timeout"` or a middleware reason keeps working.

`info.Code` says which error it was. Compare it with `Loren.Errors`. [Errors](../api-reference/errors.md#the-info-table) lists every field.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

-- in ShopController:LorenBurn(), where Shop = self.Dependencies.ShopService
Shop:Buy("Sword"):catch(function(message, info)
	if info.Code == Loren.Errors.Rejected then
		print("The shop said no:", message)
	elseif info.Code == Loren.Errors.RateLimited then
		print("Too fast, try again in a moment")
	else
		warn(message)
	end
end)
```

The ones you'll see most with calls:

| Code | What happened |
| :--- | :--- |
| `Rejected` | Your handler returned or threw `Loren.Reject`. The message is yours. |
| `Denied` | Middleware said no. The message is its reason, or `"Denied"`. |
| `Timeout` | No reply in time. See [Timeouts](#timeouts). |
| `RateLimited` | Too many calls to this method. |
| `Busy` | Too many of this player's calls are already running. See [Busy and TooManyInFlight](#busy-and-toomanyinflight). |
| `BadRequest` | The server refused the arguments, for example a NaN or a table nested too deep. |
| `BadArgument` | The client refused to send the arguments, for example more than 20 of them. |
| `InternalError` | The handler or its middleware threw. |

The [Errors](../api-reference/errors.md) page lists every code.

## Timeouts

Every method has a timeout. It's 10 seconds unless you change it:

```lua title="src/server/Services/DataService.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

local DataService = {
	Client = {},
	Spec = {
		Save = Loren.Method({ Timeout = 30 }),
	},
}

function DataService.Client:Save(player: Player)
	-- a DataStore write that can take a while
	return true
end

return DataService
```

The timeout can be 1 to 120 seconds. You can also change it for every method with `Loren.Configure({ DefaultTimeout = 15 })` on the server, or for one method with `Members` (see [Options per method](#options-per-method)).

A timeout means **you don't know what happened**. The call may never have reached the server, or the handler may still be running, or it finished just after the deadline. So write methods that are safe to retry, or check the state before you retry. A reply that arrives after the timeout is dropped and counted in `Loren.GetStats().LateReplies`.

On the server, Loren gives up on a call 5 seconds after its timeout (`WatchdogGrace`). The handler keeps running to the end unless the method has `CancelOnTimeout`. Until it ends, it counts as a "zombie": a handler nobody is waiting for. Once a player has 4 zombies on one method, their new calls to that method get `Busy`. At 16 zombies in total, every method holding one of them answers `Busy` for that player.

## Busy and TooManyInFlight

`Busy` means the server is already running too many of this player's calls. Each player can have 32 calls yielded inside handlers at once, and 64 more waiting behind them. A handler that returns without yielding doesn't count. Past that, new calls get `Busy` right away. Zombies (see [Timeouts](#timeouts)) can also cause it.

On the client, one more limit applies: 256 calls waiting for a reply at once. Past that, calls reject with `TooManyInFlight`.

## What you can send

Without a [typed spec](./typed-specs.md), arguments and return values follow these rules:

| Value | How it travels |
| :--- | :--- |
| `nil`, booleans, numbers | In Loren's buffer. Numbers arrive exactly: fractions, `-0` and large integers included. |
| Strings, buffers | In Loren's buffer, any bytes. |
| `Vector3`, `Vector2`, `Color3` | In Loren's buffer, as 32-bit floats (what Roblox stores anyway). |
| Plain arrays and string-keyed tables | In Loren's buffer, nested up to 16 levels. A plain array has keys 1 to n with no holes. |
| Instances, `CFrame`, `EnumItem`, `UDim2` and other Roblox types | Passed to Roblox's own remote serialization. An Instance the other side can't see (in `ServerStorage`, streamed out) arrives as `nil`. |
| Other tables: mixed keys, holes, non-string keys, a metatable | Copied, then passed to Roblox. The metatable is dropped. Mixed tables are unsafe, as with any RemoteEvent. |
| Functions and threads | Sent as `nil`. Studio warns once per method. |

Values are copied when you make the call. Changing a table afterwards doesn't change what's sent.

From a client, the server also enforces:

- at most 20 arguments
- tables nested at most 16 levels deep
- at most 2048 values per message
- no NaN or infinity anywhere, unless the method has `AllowNonFinite`
- keys in copied tables that are strings, booleans or finite numbers
- at most 64 KiB per message (`PayloadTooLarge` above that)

The client checks most of these before sending, so a call that breaks one rejects right away with `BadArgument`. NaN and infinity are left to the server, which answers `BadRequest`. Messages from the server have no size cap.

## Nil holes

Loren counts every argument, including nils in the middle:

```lua
Settings:Set("volume", nil, true) -- the handler gets ("volume", nil, true)
```

`select("#", ...)` inside the handler sees 3. The same goes for return values.

## Options per method

Options live in the Service's `Spec`, one `Loren.Method` per method. Options alone leave the arguments untyped:

```lua title="src/server/Services/TradeService.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

local TradeService = {
	Client = {},
	Spec = {
		Offer = Loren.Method({ RateLimit = { 2, 4 }, Serial = true }),
		Export = Loren.Method({ Timeout = 30, CancelOnTimeout = true }),
	},
}

function TradeService.Client:Offer(player: Player, itemId: any)
	return true
end

function TradeService.Client:Export(player: Player)
	return true
end

return TradeService
```

You can set the same options from outside the module with `Members`, on the server before `SetOnFire`:

```lua
Loren.Configure({
	Members = {
		["TradeService.Offer"] = { RateLimit = { 2, 4 } },
	},
})
```

When both are set, `Members` wins, then `Spec`, then the `Configure` defaults.

### RateLimit

`RateLimit = { rate, burst }` is per player, per method. The default is 50 calls a second with bursts up to 100. Past it, calls reject with `RateLimited`. The client knows the limit from the server and holds itself to 90% of it, so an honest client gets `RateLimited` straight away, without a round trip to the server.

### Serial

`Serial = true` runs one call at a time per player, in the order they arrived, middleware included. Use it for handlers that read player state, yield, then write it: a trade, a purchase that waits on a DataStore. Without it, two calls can both read the old value. Up to 8 calls per player wait in line for each Serial method (`SerialQueue`); more get `Busy`.

### CancelOnTimeout

When the server gives up on a call (its timeout plus 5 seconds), `CancelOnTimeout = true` stops the handler's thread with `task.cancel`. Without it, the handler runs to the end. Only use it for handlers that are safe to stop at any line.

### AllowNonFinite

`AllowNonFinite = true` lets NaN and infinity through in this method's arguments. Leave it off unless you need those values.

## What happens on the server

For each call, in this order:

1. The player's budgets for frames (remote fires), bytes and messages. A frame over budget is dropped whole and its calls reject `RateLimited`.
2. The method's rate limit.
3. The call caps (`Busy`).
4. The arguments are decoded and checked, including your typed spec.
5. Global middleware, then the method's own [middleware](./middleware.md).
6. Your handler.
7. The reply goes out with the next flush, at the end of the game frame (the next `Heartbeat`).

The numbers behind each step are on the [Limits](../advanced/limits.md) page. For the server-to-client direction, see [Signals](./signals.md).

---
title: Errors
sidebar_label: Errors
sidebar_position: 3
description: What a failed call gives you, every error code, and how server errors are reported.
---

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

Shop:Buy("Sword")
	:andThen(function(item: string)
		print("Bought", item)
	end)
	:catch(function(message: string, info)
		if info.Code == Loren.Errors.Rejected then
			showToast(message) -- "Not enough points", from Loren.Reject
		elseif info.Code == Loren.Errors.Timeout then
			showToast("The server didn't answer. Try again.")
		else
			warn(message)
		end
	end)
```

Every failed call rejects with two values: a `message` string and an `info` table. With `Try` you get them after `false`:

```lua
local ok, message, info = Shop.Try:Buy("Sword")
if not ok then
	warn(message, info.Code)
end
```

Here `Shop` is a Service proxy, and `showToast` stands for your own UI code.

## The message

The message is a plain string, the same one 1.5.1 used where there was one. Code that compares it keeps working:

```lua
Shop:Buy("Sword"):catch(function(message)
	if message == "(LORENঌ) Timeout" then
		-- still true in 2.0
	end
end)
```

A middleware that returns `false, "Invalid"` still rejects with `"Invalid"`, and one with no reason still rejects with `"Denied"`.

## The info table

`info` is frozen. Its fields:

| Field | Type | Meaning |
|---|---|---|
| `Code` | `string` | The code name, like `"Timeout"`. Compare it with `Loren.Errors.Timeout`. |
| `CodeId` | `number` | The code's number (table below). |
| `Message` | `string` | The same string as the first value. |
| `Service` | `string` | The Service you called. |
| `Member` | `string` | The method you called. |
| `Incident` | `string?` | Eight hex digits, like `"a1b2c3d4"`. Only for `InternalError` and `BadResult`. |
| `Arg` | `number?` | Which argument was wrong, counting from 1, for `BadRequest` and `BadArgument`. 0 when unknown. |
| `Data` | `any` | The second argument of `Loren.Reject`, if the handler gave one. |

`Loren.Errors` maps every code name to itself (`Loren.Errors.Busy == "Busy"`). Comparing with it or with the plain string works the same.

## Every code

### From the server

| Id | Code | Message | What happened | What to do |
|---|---|---|---|---|
| 1 | `Rejected` | your text | The handler returned or threw `Loren.Reject(message, data)`. | Show the message. It's your own "no". |
| 2 | `Denied` | your reason, or `Denied` | A middleware returned something other than `true`. Colon-style middleware denies every call. | Check the middleware. See [Middleware](../networking/middleware.md). |
| 3 | `BadRequest` | `(LORENঌ) BadRequest: arg 2 (Range)` | The server refused an argument: NaN or infinity, out of the Spec's range, nested too deep, too many values, bad table keys, invalid UTF-8, an unknown enum, or the wrong Instance. | Fix what you send. `info.Arg` says which argument. |
| 4 | `RateLimited` | `(LORENঌ) RateLimited` | Over the method's rate or the player's budget. The client usually catches this itself before sending. | Call less often, or raise the limit in [Configuration](./configuration.md). |
| 5 | `Busy` | `(LORENঌ) Busy` | This player has too many calls in progress: 32 running and 64 queued by default, or a full Serial queue, or stuck handlers on this method. | Make handlers finish sooner. Retry later. |
| 6 | `InternalError` | `(LORENঌ) InternalError [a1b2c3d4]` | The handler or its middleware threw an error. | Find the incident id in the server output. |
| 7 | `BadResult` | `(LORENঌ) BadResult [a1b2c3d4]` | The handler's return values couldn't be sent, for example a value outside the Spec's `Returns`. | Find the incident id in the server output. |
| 8 | `ShuttingDown` | `(LORENঌ) ShuttingDown` | The server is closing. | Nothing. The player is about to leave. |

Loren limits how many `RateLimited` (1 per method per player per second) and `BadRequest` (16 per player per second) replies it sends. When a reply is skipped, that call ends with `Timeout` instead.

### From the client itself

These never reach the server.

| Id | Code | Message | What happened | What to do |
|---|---|---|---|---|
| 16 | `Timeout` | `(LORENঌ) Timeout` | No reply within the method's timeout (10 seconds by default). | Don't assume it failed. The handler may have run. See [Calls and promises](../networking/calls.md). |
| 17 | `TooManyInFlight` | `(LORENঌ) TooManyInFlight` | This client already has 256 calls waiting (`MaxPending`). | Wait for replies before sending more. |
| 18 | `PayloadTooLarge` | `(LORENঌ) PayloadTooLarge` | The call's arguments are over 64 KiB once encoded. | Send less, or split it up. |
| 19 | `BadArgument` | `(LORENঌ) BadArgument: arg 1 (Cycle)` | The client couldn't encode an argument: more than 20, a table that contains itself, nesting deeper than 16, too many values, a value the Spec refuses, a buffer or odd key inside a table, or the send itself failed. | Fix the argument. `info.Arg` says which one. |
| 20 | `NotReady` | `(LORENঌ) NotReady` | A call before the client had the manifest (the Service list from the server). Proxies don't exist before then, so you won't normally see this. | Wait for `Loren.OnReady()`. |
| 21 | `BootFailed` | `(LORENঌ) BootFailed` | The client boot failed. Pending and later calls all get this. | Read the boot report in the output. |
| 22 | `MissingInstance` | `(LORENঌ) MissingInstance` | A typed Instance return arrived as `nil`, usually because it doesn't exist on this client. | Return Instances the client can see, or mark the return `T.optional`. |

`Loren.Reject("NotReady")` in your own handler is a `Rejected` with the message `"NotReady"`, not code 20.

## Reject

`Loren.Reject(message, data?)` ends a call on purpose:

```lua
local PRICES: { [string]: number } = { Sword = 50, Shield = 30 }

function ShopService.Client:Buy(player: Player, item: string)
	local price = PRICES[item]
	if price == nil then
		return Loren.Reject("Unknown item")
	end
	local have = self.Server.Dependencies.PointsService:GetPoints(player)
	if have < price then
		return Loren.Reject("Not enough points", { need = price - have })
	end
	-- ...
end
```

The client gets `message` and `info.Data`. Returning it and throwing it (`error(Loren.Reject(...))`) do the same thing, so you can reject from deep inside a helper function. A Promise your handler returns can reject with it too.

The message is cut to 256 bytes. `data` can be any value Loren can send.

Unlike an error, a rejection isn't logged and doesn't get an incident id. Use it for outcomes you expect: not enough points, item sold out, on cooldown.

## Server errors and incident ids

When a handler throws, the player gets `(LORENঌ) InternalError [a1b2c3d4]` and the server output gets the details under the same id:

```
(LORENঌ) ShopService.Buy failed for uid=12345 [a1b2c3d4]: ServerScriptService.Server.Services.ShopService:31: attempt to compare nil < number
<traceback>
```

Search the output for the id from the player's report and you have the traceback. The server logs the first failure of each method, then at most one line per method every 10 seconds, within Loren's limit of 10 warning lines a minute. That keeps a client from flooding your output by triggering the same error on purpose. To see every failure, use `OnError`.

### ForwardErrors

The error text stays on the server unless you say otherwise:

| `ForwardErrors` | What the client's message looks like |
|---|---|
| `"Studio"` (default) | In Studio: `(LORENঌ) InternalError [a1b2c3d4]: <error text>`. In a live game: `(LORENঌ) InternalError [a1b2c3d4]`. |
| `"Never"` | Always `(LORENঌ) InternalError [a1b2c3d4]`. |
| `"Always"` | Always includes the text. The boot warns you, because error text can reveal how your server works. |

### OnError

```lua title="src/server/Server.server.luau"
Loren.OnError(function(info)
	warn(("[%s] %s.%s: %s"):format(info.Incident, info.Service, info.Member, info.Message))
end)
```

`Loren.OnError` is called for every `InternalError` and `BadResult`, up to 10 times a second across the server. `info` has `Service`, `Member`, `Player`, `Incident`, `Message` and `Traceback` (empty for `BadResult`). Each handler runs on its own thread, and an error inside it is logged, not passed on. It works well for sending failures to your own analytics.

A ClientEvent listener that errors is logged the same throttled way, but it doesn't call `OnError`. ClientEvents have no caller waiting for an answer.

## Mistakes that raise right away

Some problems are bugs in the calling code, not network failures. Those raise an error at your line instead of rejecting a Promise:

- a dot call with arguments on a proxy, or a member name the Service doesn't have,
- `AddMiddleware`, `OnViolation`, `OnError` or `DumpManifest` on a client, or `GetController` on the server,
- `AddServices`, `AddControllers`, `Configure` or `AddMiddleware` after `SetOnFire`,
- an unknown or invalid `Configure` key,
- `Fire` on a Signal with values its Spec refuses,
- `Fire` on a ClientEvent with values its Spec refuses, more than 20 untyped arguments, or a message over the size limits (900 bytes unreliable, 64 KiB reliable),
- `proxy.Try:Method()` from a thread that can't yield.

Everything that goes wrong with a call after it leaves your code comes back as a rejection, never as a thrown error.

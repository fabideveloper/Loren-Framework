---
title: Middleware
sidebar_label: Middleware
sidebar_position: 4
description: Checks that run before a Client method or ClientEvent, and how to write them so they actually run.
---

Middleware is a function that runs before the Client method (or ClientEvent) with the same name. It gets the same arguments the handler will get. Return `true` to let the call through. Anything else blocks it.

## Write it with a dot

```lua title="src/server/Services/InventoryService.luau"
local InventoryService = {
	Client = {},
	Middleware = {},
}

local dropped: { [Player]: { [string]: number } } = {}

function InventoryService.Middleware.Drop(player: Player, item: any, amount: any)
	if type(item) ~= "string" or #item == 0 or #item > 32 then
		return false, "Invalid item"
	end
	-- Written so NaN fails too: NaN is never >= 1.
	if type(amount) ~= "number" or not (amount >= 1 and amount <= 99) or amount % 1 ~= 0 then
		return false, "Invalid amount"
	end
	if player:GetAttribute("Trading") then
		return false, "You can't drop items while trading"
	end
	return true
end

-- Runs only when the middleware returned true.
function InventoryService.Client:Drop(player: Player, item: string, amount: number): number
	local mine = dropped[player] or {}
	dropped[player] = mine
	mine[item] = (mine[item] or 0) + amount
	return mine[item]
end

return InventoryService
```

On the client, a denied call rejects with the reason:

```lua
-- in a Controller, with Inventory = self.Dependencies.InventoryService
Inventory:Drop("Apple", 0):catch(function(message, info)
	print(message, info.Code) -- "Invalid amount", "Denied"
end)
```

Note the dot in `InventoryService.Middleware.Drop`. Loren calls middleware as `(player, ...)`, with no `self`. The next section explains why the colon form is a bug.

## What the return value means

| Middleware returns | Result |
| :--- | :--- |
| `true` | The handler runs. |
| `false, "reason"` or `nil, "reason"` | Denied. The call rejects with `"reason"` (up to 256 bytes; it reaches the client, so keep secrets out of it). |
| `false`, or nothing | Denied, with the message `"Denied"`. |
| Any other value: `1`, `"yes"`, a table | Denied, and Studio warns once. 1.5.1 let these through. |
| A Promise | Loren waits for it, then applies these same rules to what it resolves with. |
| An error, or a rejected Promise | The call fails with `InternalError` and an incident id. The server log has the error. |

For a ClientEvent, "denied" means the event is dropped. There's no reply to send.

## Why the colon form is a bug

The 1.5.1 docs showed middleware written with a colon:

```lua
-- Don't write this
function InventoryService.Middleware:Drop(player, item, amount)
	-- ...
end
```

A colon adds a hidden first parameter, `self`. Loren calls middleware as `(player, item, amount)`, so `self` gets the player, `player` gets the item name the client sent, `item` gets the amount, and so on. Every check runs against the wrong values, and some of them are values an exploiter picks. `player:GetAttribute(...)` in there would run on a string from the client. This never worked, in 1.5.1 either.

2.0 catches it two ways:

- **At boot.** When a middleware has as many parameters as its Client method, Loren flags it as colon-written. It shows up in the boot warnings, and every call to that method is denied until you fix it. The server also logs a reminder when one of those calls comes in, at most once a minute per method.
- **In your source.** The boot check can't spot a colon function with fewer parameters, like `Middleware:Drop(player)` next to `Client:Drop(player, item, amount)`. It also only looks at Client methods, not ClientEvents. So a clean boot doesn't prove your middleware is right. `loren doctor` reads your files and finds every colon middleware:

```bash
loren doctor        # lists colon-style middleware
loren doctor --fix  # rewrites it to dot style; asks first, backups go to .loren-backup/
```

`loren update` runs the same check. A colon middleware that uses `self` in its body is marked "fix by hand", since dropping `self` would break it.

If the boot check ever flags a dot-style function by mistake, you can turn it off with `Loren.Configure({ MiddlewareArityCheck = false })` on the server. Run `loren doctor` before you do.

## Order and timing

- Middleware runs after Loren has decoded and checked the arguments, including your [typed spec](./typed-specs.md), and before the handler.
- Global middleware (below) runs first, in the order you added it, then the method's own.
- For a `Serial` method, the middleware waits in the same line as the handler, so it sees the state the previous call left behind.
- Loren reads `Middleware[name]` on every call, so you can set or wrap a middleware in `LorenIgnite`. Removing it removes the check.
- A `Middleware` key that matches no Client method or ClientEvent is ignored, with a boot warning and a suggestion when it looks like a typo.

## Global middleware

`Loren.AddMiddleware` adds a check that runs before every Client method and ClientEvent of every Service:

```lua title="src/server/Server.server.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

Loren.AddServices(script.Parent.Services)

Loren.AddMiddleware(function(player: Player, info, ...)
	if player:GetAttribute("Banned") then
		return false, "You're banned"
	end
	if info.Service == "AdminService" and not player:GetAttribute("Admin") then
		return false
	end
	return true
end)

-- expect() rethrows a failed boot here, so it can never fail silently.
Loren.SetOnFire():expect()
```

- It gets the player, then an `info` table, then the call's arguments. `info` is read-only and has `Service`, `Member` and `Kind` (`"Method"` or `"Event"`).
- The return rules are the same as above.
- It's server-only and has to be added before `SetOnFire`. Calling it later raises an error.

## Middleware isn't the whole story

Middleware is a good place for "may this player do this right now?". It's not a replacement for checking the game rules in the handler: the price, the cooldown, whether the player owns the item. The [Security](./security.md) page puts the pieces together.

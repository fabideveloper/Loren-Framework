---
title: Your first service
sidebar_label: Your first service
sidebar_position: 4
description: Build a Service with a Client method and a Signal, call it from a Controller, and read the boot output.
---

# Your first service

You'll build a small coin system: the server keeps each player's coins, pays everyone every 10 seconds, and lets
clients spend them. A Controller on the client shows the balance.

## 1. Make the Service

```bash
loren make service CoinService
```

```text
(LORENঌ) Created Service CoinService: src/server/Services/CoinService.luau
(LORENঌ) Types regenerated.
(LORENঌ) Sourcemap regenerated with Rojo.
```

`loren make` copies the template with the name filled in. Replace its contents with this:

```lua title="src/server/Services/CoinService.luau"
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

local CoinService = {
	Client = {},
	Signals = { "CoinsChanged" },
}

local coins: { [Player]: number } = {}

-- Server only: it isn't under Client, so clients can't call it.
function CoinService:AddCoins(player: Player, amount: number)
	coins[player] = (coins[player] or 0) + amount
	self.Signals.CoinsChanged:Fire(player, coins[player])
end

-- Clients call these. Loren passes the calling player first.
function CoinService.Client:GetCoins(player: Player): number
	return coins[player] or 0
end

function CoinService.Client:Spend(player: Player, amount: number)
	-- Anything a client sends can be wrong on purpose. Check it.
	if typeof(amount) ~= "number" or not (amount >= 1 and amount <= 1000) or amount % 1 ~= 0 then
		return Loren.Reject("Bad amount")
	end
	local have = coins[player] or 0
	if have < amount then
		return Loren.Reject("Not enough coins")
	end
	self.Server:AddCoins(player, -amount)
	return have - amount
end

function CoinService:LorenIgnite()
	Players.PlayerRemoving:Connect(function(player)
		coins[player] = nil
	end)
end

function CoinService:LorenBurn()
	while true do
		task.wait(10)
		for _, player in Players:GetPlayers() do
			self:AddCoins(player, 10)
		end
	end
end

return CoinService
```

A few things to notice:

- **Client methods** are the functions under `Client`. They're written with a colon, and the first argument after
  `self` is always the player who called. Inside them, `self.Server` is the Service itself.
- **Signals** go from server to client. List the names and Loren creates them in `self.Signals`. `Fire(player, ...)`
  sends to one player. There's also `FireAll`, `FireFor` and `FireExcept`.
- **`Loren.Reject("...")`** fails the call on purpose. The client gets your message as the error. If a handler throws
  a normal error instead, players only see `(LORENঌ) InternalError [a1b2c3d4]` with an incident id, and the full error
  goes to the server log.
- The amount check is written so that NaN fails it: `NaN >= 1` is false. Loren already refuses NaN from clients, but
  the habit is worth keeping.
- **`LorenIgnite`** (setup) runs first, in dependency order, and must not yield. **`LorenBurn`** (run) runs after
  every module's `LorenIgnite` has finished, each in its own thread, so a `while` loop there is fine.

## 2. Make the Controller

```bash
loren make controller CoinController
```

```lua title="src/client/Controllers/CoinController.luau"
local CoinController = {
	Dependencies = { "CoinService" },
}

function CoinController:LorenBurn()
	local CoinService = self.Dependencies.CoinService

	CoinService.Signals.CoinsChanged:Connect(function(total: number)
		print("Coins:", total)
	end)

	-- A call returns a Promise.
	CoinService:GetCoins()
		:andThen(function(total: number)
			print("Starting with", total)
		end)
		:catch(function(message: string)
			warn("GetCoins failed:", message)
		end)

	-- Try waits for the answer instead.
	task.wait(30)
	local ok, result = CoinService.Try:Spend(5)
	if ok then
		print("Spent 5, left:", result)
	else
		warn("Spend failed:", result) -- the error message, like "Not enough coins"
	end
end

return CoinController
```

`self.Dependencies.CoinService` is a **proxy**: a client-side stand-in for the Service. It has the Client methods,
`Signals` and `ClientEvents`, and nothing else. Two ways to call:

- `CoinService:GetCoins()` returns a Promise right away. Handle the result in `andThen` and errors in `catch`.
- `CoinService.Try:Spend(5)` waits and returns `true` plus the values, or `false`, the message and an info table.
  It yields, so use it in `LorenBurn` or your own threads, not in `LorenIgnite`.

The client never passes the player. Loren fills it in on the server. Every call has a timeout, 10 seconds unless you
change it, so a call that gets no answer fails with `(LORENঌ) Timeout` instead of hanging.

## 3. Press Play

Run `loren serve` (Rojo or Argon) and press Play. If you kept the example modules, the Output shows:

```text
(LORENঌ) Burning on Server: 2 services, 3 routes, 5 ms
(LORENঌ) Burning on Client: 2 controllers, 1 service, 210 ms
Starting with 0
Coins: 10
Coins: 20
```

About 30 seconds in, the Controller spends 5 coins and prints what's left.

The server counts 3 routes: `GetCoins`, `Spend` and `CoinsChanged`. The client sees 1 service, because only Services
with something networked (a Client method, a Signal or a ClientEvent) are sent to clients. The timings are from one
machine and yours will differ.

If the server fires `CoinsChanged` before your Controller connects, the message isn't lost: Loren keeps up to 64 per
signal and replays them on the first `Connect`, for 10 seconds after the client is ready.

## 4. Break it on purpose

In the Controller, change both `"CoinService"` in `Dependencies` and `self.Dependencies.CoinService` to `CoinServce`,
then press Play again. The client still boots, but warns:

```text
(LORENঌ) Boot warnings on Client (1):
  - CoinController.Dependencies: 'CoinServce' is not a Controller or a networked Service (a Service is networked when it has a Client method, ClientEvent or Signal); it resolves to a placeholder that raises when used. Did you mean 'CoinService'?
```

The name resolves to a placeholder, and the first line that uses it raises an error that says the same thing.

If you change only the `Dependencies` string, the read is the problem instead: `self.Dependencies.CoinService` is now
undeclared, so it returns `nil`, Studio warns `CoinController reads undeclared dependency 'CoinService'`, and the next
line fails with a plain `attempt to index nil`.

On the server the same typo is stricter. Say a `ShopService` had `Dependencies = { "CoinServce" }`. The boot stops:

```text
(LORENঌ) Boot failed on Server (1 problem):
  1. ShopService.Dependencies: 'CoinServce' is not a registered Service. Did you mean 'CoinService'?
```

Loren collects every problem it finds into that one report, so you can fix them all in one go. The report prints in
red even if nothing handles the Promise, and `:expect()` in the bootstrap stops that script there.

## Catch typos in the editor (optional)

The generated `LorenTypes` file lists your module names as types. Cast `Dependencies` to it and Luau-LSP can flag a
typo before you press Play:

```lua title="src/client/Controllers/CoinController.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.LorenTypes)

local CoinController = {
	Dependencies = { "CoinService" } :: { Types.ClientDependencyName },
}
```

The file only knows `CoinService` is networked after it sees the Client methods, so run `loren types` after you add
them (or keep `loren refresh --watch` running). Services use `LorenServerTypes` in `ServerScriptService.Server` the
same way. See [Dependencies](../core-concepts/dependency-injection.md).

## Next

- [Services](../core-concepts/services.md) and [Controllers](../core-concepts/controllers.md) cover every key a
  module can have.
- [Calls and promises](../networking/calls.md) covers timeouts, `Try` and what you can send.
- [Middleware](../networking/middleware.md) runs a check before a Client method.
- Premades (ready-made modules): `loren inject --list`. `PointsService` and `PointsController` are a similar, simpler
  pair.

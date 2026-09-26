---
title: Testing
sidebar_label: Testing
sidebar_position: 5
description: Test a Service or Controller in a spec without a server, clients or a network.
---

`Loren.Testing` wires one module the way a boot would, minus the network. Your spec calls its methods directly and checks what it fired.

```lua title="src/server/Tests/PointsService.spec.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loren = require(ReplicatedStorage.Shared.Loren)
local PointsService = require(ServerScriptService.Server.Services.PointsService)

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect
	local beforeEach, afterAll = t.beforeEach, t.afterAll

	beforeEach(function()
		Loren.Testing.Reset({ Offline = true })
		Loren.Testing.Mount(PointsService)
	end)

	afterAll(function()
		Loren.Testing.Reset()
	end)

	describe("AddPoints", function()
		it("adds to the total and fires PointsChanged", function()
			local player = { UserId = 1, Name = "Tester" } -- a stand-in; scripts can't create a Player

			expect(PointsService:AddPoints(player, 5)).toBe(5)
			expect(PointsService:AddPoints(player, 3)).toBe(8)

			local fired = Loren.Testing.Fired(PointsService.Signals.PointsChanged)
			expect(#fired).toBe(2)
			expect(fired[2].Method).toBe("Fire")
			expect(fired[2].Target).toBe(player)
			expect(fired[2].Args[1]).toBe(8)
		end)
	end)

	describe("Client.GetPoints", function()
		it("returns the caller's points", function()
			local player = { UserId = 2, Name = "Tester" }
			PointsService:AddPoints(player, 4)
			expect(PointsService.Client:GetPoints(player)).toBe(4)
		end)

		it("is blocked by its middleware for a player who left", function()
			local gone = { UserId = 3, Name = "Gone", Parent = nil }
			expect(PointsService.Middleware.GetPoints(gone)).toBe(false)
		end)
	end)
end
```

This tests the `PointsService` premade, a ready-made module that ships with the CLI (`loren inject service PointsService`).

Loren doesn't ship a test runner. The spec above uses the shape Loren's own test suite uses: the module returns a function that gets `describe`, `it`, `expect` and the hooks, and the matchers are Jest-style (`expect(x).toBe(y)`). If you use Jest Lua, TestEZ or something else, change those lines and keep the `Loren.Testing` calls.

Keep specs outside the folders you pass to `AddServices` and `AddControllers`. Those register every ModuleScript they find, specs included.

## Mount

```lua
Loren.Testing.Mount(module, {
	Dependencies = { DataService = fakeData }, -- optional: what self.Dependencies holds
	Kind = "Service", -- or "Controller"; default "Service"
	Name = "PointsService", -- optional: used in error messages
})
```

`Mount` returns the module and changes it in place, like a boot would:

- It checks the module's shape with the same rules as a boot (it doesn't look up dependency names). A problem raises an error with the report text.
- `Client.Server` is set to the module.
- `Dependencies` becomes the table you pass, or `{}`.
- For a Service, each `Signals` name becomes a recording object. `Fire`, `FireAll`, `FireFor` and `FireExcept` don't send anything; they record the call for `Fired`. Each `ClientEvents` name becomes a real event object that you drive with `Emit`.
- For a Controller, each `Signals` name becomes a local signal.

`Mount` doesn't run `LorenIgnite` (setup) or `LorenBurn` (run). Call them yourself when the test needs them.

## Fired

```lua
local fired = Loren.Testing.Fired(PointsService.Signals.PointsChanged)
-- { { Method = "Fire", Target = player, Args = { 8, n = 1 } } }
```

Each entry has `Method` (`"Fire"`, `"FireAll"`, `"FireFor"` or `"FireExcept"`), `Target` (the player, the list of players, or `nil` for `FireAll`) and `Args`, packed with `table.pack` so `Args.n` counts `nil`s too. It's the live list: clear it with `table.clear(fired)` if you want to start over mid-test.

## Emit

`Emit` delivers a ClientEvent as if a player fired it:

```lua title="src/server/Services/EmoteService.luau"
local EmoteService = {
	ClientEvents = { "Emote" },
	Signals = { "Emoted" },
}

local ALLOWED = { wave = true, cheer = true }

function EmoteService:LorenIgnite()
	self.ClientEvents.Emote:Connect(function(player: Player, name: any)
		if ALLOWED[name] then
			self.Signals.Emoted:FireExcept(player, player, name)
		end
	end)
end

return EmoteService
```

```lua
it("only broadcasts allowed emotes", function()
	Loren.Testing.Mount(EmoteService)
	EmoteService:LorenIgnite() -- Mount doesn't run it

	local player = { UserId = 4, Name = "Tester" }
	Loren.Testing.Emit(EmoteService.ClientEvents.Emote, player, "wave")
	Loren.Testing.Emit(EmoteService.ClientEvents.Emote, player, "dance")

	local fired = Loren.Testing.Fired(EmoteService.Signals.Emoted)
	expect(#fired).toBe(1)
	expect(fired[1].Method).toBe("FireExcept")
	expect(fired[1].Args[2]).toBe("wave")
end)
```

Listeners run before `Emit` returns, unless they yield. A listener that errors is caught and logged, and the other listeners still run, as on a live server.

## Controllers

Mount a Controller with `Kind = "Controller"` and hand it fake proxies. A fake proxy is a table with the methods your Controller calls:

```lua
local Promise = require(ReplicatedStorage.LorenPackages.Promise)

local fakeShop = {
	Buy = function(_self, item: string)
		return Promise.resolve(item)
	end,
}

Loren.Testing.Mount(ShopController, {
	Kind = "Controller",
	Dependencies = { ShopService = fakeShop },
})
```

## Reset

```lua
Loren.Testing.Reset() -- back to the state right after require
Loren.Testing.Reset({ Offline = true }) -- the same, and the next server boot runs offline
```

`Reset` puts back every key Loren replaced in your modules (`Signals`, `ClientEvents`, `Dependencies`, `Client.Server`), clears registrations and settings, and stops any boot. Your modules' own state, like a `points` table, is yours to clear. Using a new stand-in player per test avoids most of that.

`{ Offline = true }` makes the next `SetOnFire` on the server boot without a network: no remotes, no players, no shutdown hook. Use it when a spec needs a real boot, for example to check the start order:

```lua
it("boots every Service", function()
	Loren.Testing.Reset({ Offline = true })
	Loren.AddServices(ServerScriptService.Server.Services)
	Loren.SetOnFire():expect()
	expect(Loren.State).toBe("Ready")
end)
```

:::warning
`Reset` tears down the whole runtime, including a boot your game started. Run specs before your bootstrap script calls `SetOnFire`, or in a place where it doesn't run, and call `Loren.Testing.Reset()` when the specs are done.
:::

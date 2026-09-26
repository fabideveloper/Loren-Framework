---
title: FAQ and troubleshooting
sidebar_label: FAQ
sidebar_position: 8
description: What Loren's boot report, warnings and call errors mean, and how to fix the common ones.
---

# FAQ and troubleshooting

Every message Loren prints starts with `(LORENঌ)`, so you can filter the Output window by it.

## Reading the boot report

When the boot fails, Loren prints one report with every problem it found, numbered, then any warnings:

```text
(LORENঌ) Boot failed on Server (2 problems):
  1. ShopService.Dependencies: 'DataServce' is not a registered Service. Did you mean 'DataService'?
  2. ShopService.Signals must be an array of names like { "A", "B" } (got string)
Warnings (1):
  - AdminService.Middleware.Kick looks colon-defined (3 parameters, like Client:Kick). Middleware is called as (player, ...args) without self, so every Kick call is DENIED until you write: function AdminService.Middleware.Kick(player, ...)
```

- **Problems** stop the boot. No `LorenIgnite` (setup) runs until they're all fixed.
- **Warnings** don't stop it. After a good boot they come right after the "Burning on Server" line, the line Loren
  prints when the boot is done, under `Boot warnings on Server`.
- Each line starts with the module and the key, like `ShopService.Dependencies`, so you know where to look.

The report prints in red even if nothing handles the boot Promise. The client has its own report
(`Boot failed on Client`).

## "is not a registered Service. Did you mean …?"

```text
ShopService.Dependencies: 'DataServce' is not a registered Service. Did you mean 'DataService'?
```

A name in `Dependencies` (or in `Loren.GetService`) doesn't match any registered Service. Loren suggests the closest
name when there's one. Otherwise it lists what's registered. Common causes:

- A typo, or different capitalization.
- The Service is in a sub-folder of `Services`. Only direct children register, unless you pass
  `{ Recursive = true }` to `AddServices`.
- The module failed to load. Then the report has a `failed to load` line for it, and that's the one to fix.

## "LorenIgnite yielded; the boot waits for it"

```text
(LORENঌ) DataService:LorenIgnite yielded; the boot waits for it (move yielding work to LorenBurn)
```

`LorenIgnite` (setup) should finish right away. Something in it waited: `task.wait`, `WaitForChild`, a DataStore or
HTTP call, or `proxy.Try`. The boot waits for it, so every module after it starts late. Move the waiting part to
`LorenBurn` (run), which runs in its own thread:

```lua
function DataService:LorenIgnite()
	self.cache = {} -- setup only
end

function DataService:LorenBurn()
	self.map = workspace:WaitForChild("Map") -- waiting is fine here
end
```

If you'd rather fail the boot than wait forever, set a limit: `Loren.Configure({ IgniteTimeout = 30 })` before
`SetOnFire`.

## A Controller depends on a Service it can't use

```text
HudController.Dependencies: 'StatsService' is not a Controller or a networked Service (a Service is networked when it has a Client method, ClientEvent or Signal); it resolves to a placeholder that raises when used.
```

Clients only get Services that have something networked: a Client method, a Signal or a ClientEvent. A server-only
Service isn't sent to them, and from the client a missing Service looks the same as a typo. So the boot warns and
gives the Controller a placeholder. The first time you use it, you get an error with the same explanation.

Fix: give the Service a Client method or a Signal the Controller needs, or remove the dependency. If it's a typo, the
warning ends with `Did you mean …?`.

## Colon-style middleware

```text
AdminService.Middleware.Kick looks colon-defined (3 parameters, like Client:Kick). … every Kick call is DENIED until you write: function AdminService.Middleware.Kick(player, ...)
```

Loren calls middleware as `(player, ...)`, without `self`. Written with a colon, `self` gets the player and your
`player` gets the client's first argument, which a client controls. So 2.0 denies every call to that member until you
switch to a dot:

```lua
function AdminService.Middleware.Kick(player: Player, target: Player)
	return player.UserId == game.CreatorId
end
```

`loren doctor --fix` rewrites them for you. The boot check only spots colon functions with as many parameters as the
Client method, so also search your code for `Middleware:`. Remember that middleware must return `true` to allow a call.
See [Middleware](./networking/middleware.md).

## RateLimited, Busy and Timeout

These are rejections from a call. The Promise rejects with a message and an info table:

```lua
Shop:Buy(itemId):catch(function(message, info)
	if info.Code == Loren.Errors.RateLimited then
		-- slow down
	end
	warn(message)
end)
```

| Message | What happened | What to do |
|---|---|---|
| `(LORENঌ) RateLimited` | This player called one method faster than its limit: 50 a second, with bursts up to 100, unless you changed it. The client refuses early, before the server has to. | Call less often, or batch. Raise the method's limit with `RateLimit` in its `Spec`, or with `Members` in `Loren.Configure`. |
| `(LORENঌ) Busy` | This player has too many calls waiting on the server (32 running and 64 queued), or the method has handlers stuck past their timeout. | Make handlers finish. Look for a handler that waits on something that never comes. |
| `(LORENঌ) Timeout` | No answer within the method's timeout, 10 seconds by default. | Give slow methods a longer `Timeout` in their `Spec`. |

A timeout means you don't know the outcome: the server may still have run the method. Make actions that players retry
safe to repeat. See [Calls and promises](./networking/calls.md) and [Errors](./api-reference/errors.md) for every code.

## A call fails with "InternalError [a1b2c3d4]"

The handler (or its middleware) threw an error. Players only see the incident id. The server log has the full error
with the same id:

```text
(LORENঌ) ShopService.Buy failed for uid=12345 [a1b2c3d4]: ServerScriptService.Server.Services.ShopService:40: attempt to index nil with 'Price'
```

In Studio the error text is forwarded to the client too, so you see it while you test. For failures players should
read, return `Loren.Reject("Not enough coins")` instead of throwing.

## `Loren.IsClient` is false in Run mode

Studio's Run mode (F8) starts a server with no player. There, `Loren.IsServer` is `true` and `Loren.IsClient` is
`false`. 1.5.1 said `true` for both. `AddControllers` is ignored in Run mode with a warning, since no client runs. Use
`Loren.IsServer` to pick a side, and use Play to test Controllers.

## The boot line says "(offline)"

```text
(LORENঌ) Burning on Server: 3 services, 7 routes, 2 ms (offline)
```

Loren booted without a running game: in Edit mode (the command bar or a plugin, for example), or in specs after
`Loren.Testing.Reset({ Offline = true })`. Offline there's no `LorenNet`, no remotes and no players. `LorenIgnite` and
`LorenBurn` still run, and firing a signal does nothing.

## "call Loren.OnReady() first"

```text
(LORENঌ) GetService('ShopService') was called before the client received the server manifest; call Loren.OnReady() first
```

On the client, `Loren.GetService` needs the manifest: the list of Services the server sends during the boot. Code
outside a Controller that runs early has to wait for it:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

Loren.OnReady():andThen(function()
	local Shop = Loren.GetService("ShopService")
	Shop:Buy(1):catch(warn)
end)
```

Inside a Controller, list the Service in `Dependencies` instead. It's ready by the time `LorenIgnite` runs.

## A remote spy shows one RemoteEvent full of buffers

That's Loren. Everything goes through `ReplicatedStorage.LorenNet.Reliable` (and `.Unreliable`), packed into buffers,
one batch per game frame. This isn't encryption. Anyone determined can decode the bytes, and the list of networked Services
and methods is sent to every client, because the client needs it to call them. Loren's protection is on the server:
it checks every packet before your code runs. Keep your own checks on prices, cooldowns and ownership. See
[Security](./networking/security.md).

## Can I use my own RemoteEvents too?

Yes. Keep them outside `LorenNet`. Loren sends its batch at the end of the game frame, so a RemoteEvent of yours fired
later in the same game frame may arrive before Loren's messages. If the order matters, call `Loren.Flush()` before firing your
own remote.

## Where did LorenBridge go?

2.0 removed `LorenBridge` and `LorenHandshake`. The handshake used a RemoteFunction that any client could call to read
every route id. Now the server creates `ReplicatedStorage.LorenNet` once it's ready, and the handshake happens inside
Loren's own messages. If your code touched `LorenBridge`, move that feature to a Signal, a Client method or a
ClientEvent.

## How do I go back to 1.5.1?

```bash
npm i -g loren-framework@latest
```

That restores the 1.5.1 CLI. For a project you already updated, see
[Rolling back](./getting-started/upgrading.md#rolling-back).

## Something else is wrong

Run `loren doctor` in the project root. If that doesn't explain it,
[open an issue](https://github.com/fabideveloper/Loren-Framework/issues) and paste the boot report.

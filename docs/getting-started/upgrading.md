---
title: Upgrading from 1.5.1
sidebar_label: Upgrading from 1.5.1
sidebar_position: 5
description: Move a 1.5.1 project to the 2.0 beta with loren update, fix what needs fixing, and roll back if you have to.
---

# Upgrading from 1.5.1

```bash
npm i -g loren-framework@next
cd my-game
loren update --dry-run
loren update
```

Your Services and Controllers keep working: same module shape, same `require(ReplicatedStorage.Shared.Loren)`.
What changes is the runtime underneath. Most projects need no code changes, but read [Must edit](#must-edit) before
you ship.

Commit your project (or copy the folder) first. `loren update` backs up everything it replaces, but version control
is easier to undo.

## 1. Install the beta CLI

```bash
npm i -g loren-framework@next
loren --version
```

It should print `2.0.0-beta.1`. The CLI carries the runtime, so a newer CLI is what brings 2.0 to your project.

## 2. Preview the update

Run this in the project root (the folder with `default.project.json`):

```bash
loren update --dry-run
```

It prints the plan and a preview of the middleware check (the CLI prints it as "Middleware lint"), and changes
nothing. Here's a project made with the 1.5.1 CLI, plus one colon-style middleware:

```text
(LORENঌ) Loren 1.5.1 project (src/shared/Loren.luau is the whole 1.x runtime). This CLI ships runtime 2.0.0.
(LORENঌ) Would do:
  - add loren/ with runtime 2.0.0 (27 files)
  - write the shim to src/shared/Loren.luau (replaces the 1.5.1 runtime)
  - patch default.project.json: added ReplicatedStorage.LorenRuntime -> loren/shared; added ServerScriptService.LorenServer -> loren/server; globIgnorePaths += loren_packages/**/*.spec.lua, loren_packages/**/*.spec.luau
  - vendor loren_packages/Promise (lib/init.lua, LICENSE, default.project.json): default.project.json is not the minimal one; it has test files (lib/init.spec.lua) that would build into your place
  - regenerate src/shared/LorenTypes.luau and src/server/LorenServerTypes.luau
  Replaced files are backed up to .loren-backup/2026-09-25T21-53-48-764Z/.
(LORENঌ) Then: sourcemap, and the middleware lint (preview below). Dry run: nothing was changed.
(LORENঌ) Middleware lint: 1 issue.
  src/server/Services/ShopService.luau:6 [fixable] ShopService.Middleware:Buy is colon-style. Loren calls middleware as (player, ...args) without self, so 2.0 denies every Buy call. Dot style: function ShopService.Middleware.Buy(player, itemId)
(LORENঌ) Run `loren doctor --fix` to rewrite colon-style middleware to dot style.
```

## 3. Update

```bash
loren update
```

It asks before it changes anything. `--yes` skips every question, including the middleware rewrite below. Without a
terminal (in CI, for example) it won't ask: it stops with exit code 2 until you pass `--yes`.

What it does:

- Adds the runtime in `loren/` and maps it in `default.project.json` (`ReplicatedStorage.LorenRuntime` and
  `ServerScriptService.LorenServer`).
- Replaces `src/shared/Loren.luau`, the old single-file runtime, with a six-line shim, so your `require` paths stay
  the same.
- Makes sure `loren_packages/Promise` is the bundled copy, without test files.
- Writes the type files, rebuilds the sourcemap, and runs the middleware check.

Everything it replaces goes to `.loren-backup/<timestamp>/` first. It doesn't touch your Services or Controllers,
except for the middleware rewrite if you say yes. Running it twice is safe: the second run says it's already up to
date.

## 4. Fix colon-style middleware

If the check found middleware written with a colon, `loren update` offers to rewrite it. You can also do it later:

```bash
loren doctor --fix
```

```lua title="Before (never worked)"
function ShopService.Middleware:Buy(player, itemId)
```

```lua title="After"
function ShopService.Middleware.Buy(player, itemId)
```

Items marked `[fix by hand]` use `self` inside the function, so Loren leaves them to you. See
[Middleware](../networking/middleware.md) for why the colon form is a bug.

## 5. Press Play and read the boot report

Sync the project as usual (`loren serve`) and press Play. A good boot prints one line per side, plus warnings if
there are any:

```text
(LORENঌ) Burning on Server: 4 services, 9 routes, 6 ms
(LORENঌ) Boot warnings on Server (1):
  - ShopService.Client.Try uses a reserved name and is not networked (reserved: ClientEvents, Properties, Server, Signals, Try)
```

If something is wrong, the boot stops and prints one numbered report with every problem. Fix them and press Play
again. The [FAQ](../faq.md) explains the common ones.

## Must edit

These are the 1.5.1 patterns that need a change. The boot report or `loren doctor` points at most of them.

- **Colon-style middleware.** `function X.Middleware:Buy(player, ...)` never did what it looked like: Loren calls
  middleware as `(player, ...)`, so `self` got the player and your `player` got the client's first argument. 2.0
  denies every call to that member and warns at boot. Rewrite it with a dot (step 4). The boot check only catches
  colon functions with as many parameters as the Client method, so also search your code for `Middleware:`.
- **Middleware that returns something other than `true`.** Only `true` lets a call through now. `1`, `"ok"` or any
  other value blocks it. `return false, "reason"` still sends the reason.
- **Service keys named `Spec` or `ClientEvents`.** 2.0 reads these keys. If you used them for your own data, rename
  them. `loren doctor` warns about them.
- **Controllers that depend on a server-only Service.** A Service with no Client methods, Signals or ClientEvents is
  no longer sent to clients. The Controller gets a boot warning and a placeholder that errors when used. Give the
  Service something networked, or drop the dependency.
- **Code that uses `LorenBridge` or `LorenHandshake`.** Both are gone. Use Signals, Client methods or ClientEvents.
- **Registration mistakes 1.5.1 let through.** These now stop the boot with a clear message:
  - `Dependencies`, `Signals` or `ClientEvents` that aren't lists of names
  - two modules with the same name
  - a Client method and a ClientEvent with the same name
  - `AddServices` after `SetOnFire`
  - a frozen module table that Loren has to write to
- **Reserved Client method names.** `Server`, `Signals`, `ClientEvents`, `Properties` and `Try` can't be Client
  methods. They're skipped with a warning. Rename them.
- **Lowercase module folders.** Loren registers `Services` and `Controllers`. `loren update` warns if it finds
  `services` or `controllers`, which some 1.5.1 `loren inject` runs created. Move the modules.

## Every behavior change

The full list of things that work differently in 2.0, and what to do about each.

| # | What changed | What you'll notice | What to do |
|---|---|---|---|
| 1 | `Loren.SetOnFire()` resolves with `Loren` once every module has started. A second call returns the same boot. A failed boot rejects with the report and prints it in red, even if nothing handles it. | Boot failures are loud. A second `SetOnFire` waits for the first boot. | Nothing. Keep `:expect()` on the bootstrap call. `Loren:SetOnFire()` with a colon still works. |
| 2 | `LorenIgnite` (setup) and `LorenBurn` (run) go in dependency order: a module starts after the ones it lists. 1.5.1 used table order, which was effectively random. Cycles are allowed. A yielding `LorenIgnite` makes the boot wait and warns. | Modules may start in a different order. You may see `X:LorenIgnite yielded; the boot waits for it`. | List what a module needs in `Dependencies`. Move waits (`WaitForChild`, DataStores, HTTP) to `LorenBurn`. |
| 3 | `LorenBridge` and the `LorenHandshake` RemoteFunction are gone. Loren uses `ReplicatedStorage.LorenNet` with two remotes that appear once the server is ready. Controllers' `LorenIgnite` runs after that. A slow client warns but keeps waiting: after 60 s without the server, and after 30 s without the manifest (the Service list the server sends). | The client boot starts after the server is up. Code that looked for `LorenBridge` breaks. | Remove that code. Don't fire Loren's remotes yourself. |
| 4 | Messages go out in batches. The server sends once per Heartbeat, the client at most 61 times a second. | Up to one Heartbeat plus up to 1/61 s of extra delay. | Nothing. `Loren.Flush()` sends what's queued right away. |
| 5 | Loren sends at the end of the game frame, not the moment you call. Tables are still copied the moment you call, as before. | A RemoteEvent of your own fired later in the same game frame may arrive first. An Instance you send and then destroy in the same game frame arrives as `nil`. | Call `Loren.Flush()` first when that order matters. |
| 6 | Refused calls fail right away with a reason (`RateLimited`, `BadRequest`, `Busy`, `InternalError`) instead of timing out. The rate limit is now per method: 50 a second, bursts of 100 (1.5.1 had 50 a second for all calls together). Dropped traffic gets one log line per player every 30 s. | Errors arrive fast and say why. Far fewer log lines. | Handle rejections where you call. Give a busy method a higher `RateLimit` in its `Spec`. |
| 7 | A handler error reaches players as `(LORENঌ) InternalError [a1b2c3d4]`. The full error goes to the server log with the same incident id. In Studio the text is still forwarded. Rejections pass `(message, info)`. In middleware, only `true` allows, a thrown error becomes `InternalError`, and a returned Promise is waited for. | Live players no longer see your error text. Middleware returning `1` or `"ok"` starts denying. | Use `Loren.Reject("message")` for errors players should read. Return `true` from middleware. Code comparing `msg == "(LORENঌ) Timeout"` still works. |
| 8 | Untyped client arguments are refused if they hold NaN or infinity, tables nested deeper than 16 levels, more than 2,048 values, or keys that aren't strings, booleans or finite numbers (1.5.1 turned those keys into strings). The server answers `BadRequest`, or the client refuses first with `BadArgument`. | Honest clients rarely notice. A table keyed by Instances, for example, now fails. | Use string keys, or an array of pairs. |
| 9 | `nil` between arguments or return values stays in place: `M(1, nil, 3)` arrives as `1, nil, 3`. A handler that returns a Promise is waited for, and the client gets its result. | Argument counts can differ if your code relied on nils being dropped. | Usually nothing. |
| 10 | Signal messages that arrive before anything is connected are kept (up to 64 per signal) and replayed to the first `Connect`, within 10 s after the client is ready. Messages for a player whose client isn't ready yet wait instead of being lost. | Listeners get messages fired at join or during boot, which 1.5.1 dropped. | For no replays: `Backlog = 0` in `Loren.Configure`, or `Loren.Signal({ Backlog = 0 })` in a Service's `Spec`. |
| 11 | `connection:Disconnect()` and `connection.Disconnect()` both work and are safe to call twice. A listener disconnected during a fire is skipped. One connected during a fire starts with the next fire. | Nothing, in most code. | Nothing. |
| 12 | These now raise an error with a hint: `Connect` on a server signal, `Fire` on a client signal, a name a proxy or `self.Signals` doesn't have, and a dot call with arguments (`Svc.Buy(1)`). `Fire` to a player who left does nothing. | Errors where 1.5.1 did nothing or shifted every argument. | Call with `:`. `Svc.Method()` with no arguments still works. Don't test `self.Signals.X == nil`, because the lookup raises. |
| 13 | In Studio's Run mode (server only), `Loren.IsClient` is `false`. 1.5.1 said `true`. `AddControllers` is ignored there with a warning. Booting in Edit mode runs offline: no remotes, no players. | `IsClient` checks behave differently in Run mode. | Use `Loren.IsServer` to pick a side. |
| 14 | Services with nothing networked aren't sent to clients. ModuleScripts in sub-folders are skipped with a Studio warning (pass `{ Recursive = true }` to include them). Reading an undeclared name from `self.Dependencies` warns in Studio. | Boot warnings you didn't get before. | See [Must edit](#must-edit). |
| 15 | More than 255 Services, or more than 255 members in one Service, work. 1.5.1 could send calls to the wrong handler past that. | Nothing. | Nothing. |
| 16 | Each method has its own timeout (still 10 s by default), and a reply after the timeout is dropped. A player with too many calls in progress gets `Busy` (numbers in [Calls and promises](../networking/calls.md#busy-and-toomanyinflight)). During shutdown, new calls get `ShuttingDown`. | Heavy bursts of slow calls can get `Busy`. | Give slow methods a longer `Timeout` in their `Spec`. Make handlers finish. |
| 17 | A call with more than 20 arguments rejects with `BadArgument`, and one over 64 KiB with `PayloadTooLarge`, before it leaves the client. | Calls that 1.5.1 dropped without a word now fail with a reason. | Put many arguments in one table. Split big uploads. |
| 18 | A Controller's `Signals = { "Opened" }` becomes local signals you can `Fire` and `Connect` on the client. If `Signals` isn't a list of names, Loren leaves it alone, as 1.5.1 did. The boot line now reads `Burning on Server: <n> services, <n> routes, <n> ms`. | Controller signals work with no extra code. | Update anything that matched the old boot line text. |

## Installing by hand

`loren update` needs a normal `default.project.json` (a tree with `$className` `DataModel`). If yours is unusual, it
changes nothing and prints what to add. You can also install 2.0 by hand, for example in a place that doesn't use a
project file.

The runtime ships inside the CLI. `npm root -g` prints the folder that holds it:

| From the CLI package | Put it at |
|---|---|
| `loren-framework/project/loren/shared/` (a folder module) | `ReplicatedStorage.LorenRuntime` |
| `loren-framework/project/loren/server/` (a folder module) | `ServerScriptService.LorenServer` |
| `loren-framework/project/loren_packages/Promise/lib/init.lua` | `ReplicatedStorage.LorenPackages.Promise` |
| `loren-framework/project/src/shared/Loren.luau` (the shim) | in place of your old `Loren` module, usually `ReplicatedStorage.Shared.Loren` |

A folder module is a ModuleScript made from the folder's `init.luau`, with the other files as ModuleScripts inside
it. Rojo and Argon build that for you from a `$path`. The server runtime looks for `ReplicatedStorage.LorenRuntime`
and `ReplicatedStorage.LorenPackages.Promise` by those exact paths. `LorenServer` can sit anywhere under `ServerScriptService`. With Rojo or Argon, the mappings look like
this:

```json title="default.project.json (excerpt)"
{
    "globIgnorePaths": ["loren_packages/**/*.spec.lua", "loren_packages/**/*.spec.luau"],
    "tree": {
        "$className": "DataModel",
        "ReplicatedStorage": {
            "LorenRuntime": { "$path": "loren/shared" }
        },
        "ServerScriptService": {
            "LorenServer": { "$path": "loren/server" }
        }
    }
}
```

## Rolling back

For the CLI:

```bash
npm i -g loren-framework@latest
```

During the beta, `latest` is 1.5.1. For a project, the simplest way back is your version control. Without it, use
`.loren-backup/<timestamp>/` from the update: it holds every file `loren update` replaced, at the same paths
(`src/shared/Loren.luau`, `default.project.json`, Promise). Copy those back and delete `loren/`. Middleware rewritten
to dot style is correct for 1.5.1 too, so you can keep it.

If you try the beta and something breaks, please [open an issue](https://github.com/fabideveloper/Loren-Framework/issues)
with the boot report.

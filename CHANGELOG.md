# Changelog

## 2.0.0-beta.2

Networking is much faster, and nothing in your code has to change. Install it with `npm i -g loren-framework@next`, then run `loren update` in your project.

**Faster** (Roblox Studio, 1 player, work per game frame)
- 1,000 Signal messages in one frame: receiving is about 5x faster (about 1.0 ms down to 0.18 ms), sending about 3x (0.46 ms down to 0.14 ms).
- 100 entity updates in one frame: receiving is about 2x faster, sending about 1.7x.
- 1,000 client events in one frame: the client sends them about 3x faster, and the server handles them about 2x faster.
- A client packs up to 60 KB into one send instead of 16 KB, so heavy client traffic needs fewer remote calls (1 a frame instead of 4 in our untyped test).

**Changed**
- Each Signal carries its own `Fire`, `FireAll`, `FireFor` and `FireExcept`. Calls work as before. You'd only notice it if you loop over a Signal with `pairs`, or compare the `Fire` of two Signals.
- Signal and ClientEvent listeners run on a reused thread instead of a new thread for every message. A listener that yields still doesn't hold up the others, and errors are caught as before.
- The shim's "LorenRuntime missing" error starts with `(LORENঌ)`, like every other Loren message. `loren update` replaces the old shim (it calls it "a changed shim") and keeps a backup.

**The same as beta.1**
- The message format, error messages, rate limits, counters and every security check. In Studio all 1,555 tests pass, and the exploiter bot still gets 0 of 48,783 junk packets through.

## 2.0.0-beta.1

The first 2.0 beta. Your 1.5.1 Services and Controllers keep working as they are. Install it with `npm i -g loren-framework@next`, then run `loren update` in your project.

**Upgrading**
- `loren update` moves a project to 2.0: it backs up what it replaces, installs the runtime, writes the shim, patches `default.project.json` and regenerates your types.
- `loren doctor` finds colon-style middleware (`function S.Middleware:Buy(...)`) and offers to rewrite it to dot style. 1.5.1 silently called those with the wrong arguments.

**Networking**
- Everything a client and the server send each frame goes out as one packed buffer instead of one remote call per message. A 64-byte call costs about 76 bytes on the wire.
- Server errors no longer reach clients as raw text. Players get `InternalError [id]`, and you get the full error in the server log.
- Failed calls reject right away with a clear reason (`RateLimited`, `Busy`, `BadRequest`...) instead of waiting out a 10 second timeout.
- Signals fired before a controller connects are kept and replayed, instead of being lost.
- New: client events (reliable, unreliable and ordered), optional typed schemas with `Spec` and `T`, `FireFor` and `FireExcept`.

**Security**
- Malformed packets are rejected before your code runs. In our Studio test an exploiter sent 48,190 junk packets: none got through, honest players stayed at 100%, and the server logged no warnings during the attack.
- Rate limits per player and per method, violation scoring, and optional kicking with `KickScore` (off by default).
- The handshake RemoteFunction is gone, so the route list can't be pulled with `InvokeServer`.

**Lifecycle**
- `LorenIgnite` runs in dependency order. Dependency cycles are allowed and silent by default. Turn on `CycleWarnings` to list them, or `StrictCycles` to make them boot errors.
- A failed boot fails loudly and never leaves the network half open.
- New: `Loren.OnReady`, `Loren.GetService`, `Loren.GetController`, `LorenExtinguish`, and `Loren.Testing` for testing modules without networking.

**CLI**
- `loren init` asks for Rojo, Argon, or None (Roblox Script Sync).
- New commands: `update`, `doctor` and `types`. The other commands got fixes: name checks, correct folder casing, real exit codes, and no hanging without a terminal.
- New projects no longer build the bundled Promise library's test file into your place.

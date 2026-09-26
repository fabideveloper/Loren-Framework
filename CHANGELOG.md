# Changelog

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

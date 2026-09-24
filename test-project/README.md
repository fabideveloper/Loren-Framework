# Loren Studio tests

Check, stress and security tests that run in real Roblox Studio (server + N clients). One Rojo project per runtime:

| Project | Runtime |
|---|---|
| `rojo serve default.project.json` | Loren 2.0 (`cli/project/loren`, `Shared.Loren` = the shim) |
| `rojo serve baseline.project.json` | Loren 1.5.1 (`baseline/Loren151.luau`) |
| `rojo serve raw.project.json` | plain RemoteEvents, no framework (`rojo build <project> -o x.rbxl` works too) |

## Run

1. Connect Rojo, then set the attributes on `ReplicatedStorage.TestConfig`:
   - `Scenario`: `check` (all specs), `stress`, `burst`, `security`, `soak`, `compare`, or `all` (check, stress, security).
   - `Duration` (s), `Rate` (calls/s per client and Ticks/s), `PayloadSize` (bytes). For `soak`, use a long `Duration` (600+).
   - `Clients`: leave at `0` (auto: the test starts 3 s after the last client joins). Set a number only to wait for exactly that many.
2. Press **Play** (one client), or use **Test > Clients and Servers** for several (`security` needs 2+). Run mode (F8) runs the server specs only.
3. Read the REPORT in the **server** Output (entries start with `[LorenTest]`); it ends with `RESULT: PASS|WARN|FAIL` (also saved to `TestConfig.LastResult`). `compare` prints a `COMPARE_JSON` line to diff runtimes.
   During `check`, red and yellow lines in the Output are expected (specs trigger errors on purpose); only the CHECK REPORT and its `RESULT` decide pass or fail.

The runtime is auto-detected: `LorenRuntime` = 2.0 (confirmed by `Loren.Version` once `Shared.Loren` loads), `LorenBridge`/`Shared.Loren` = 1.5.1, otherwise raw. Numbers are relative, since everything shares one machine.

## Layout

- `runner/LorenTest.luau`: the spec runner (`describe`/`it`/hooks/`expect`/`spy`, timeouts, yielding tests).
- `fixtures/`: plain 1.5.1-style Services and `TestController` (they must run unchanged on 2.0). `fixtures/v2/{Services,Controllers}` are registered on 2.x only.
- `bots/`: `CallSpammer`, `SignalWatcher`, `Burst`, `Exploiter`, `Soak` (plus the `CallKit` helper).
- `studio/`: `Server.server.luau`, `Client.client.luau`, `Harness/`, `ServerHarness/`. `raw/`: the fixture API on one RemoteEvent.
- `specs/`: `runner`, `studio/{server,client}`, `unit` and `v2` (2.0 only; `check` runs `unit` before the fixtures boot, then `Loren.Testing.Reset()`).

## Add a spec

Create `specs/studio/client/Name.spec.luau` (or `server`, `v2/...`) returning `function(t)`:

```lua
local Harness = game:GetService("ReplicatedStorage").LorenTest.Harness
local Env, Budget = require(Harness.Env), require(Harness.Budget)
return function(t)
	t.it("echoes", function()
		Budget.take(1) -- stays under 1.5.1's 50 calls/s limit
		local ok, v = Env.proxy("EchoService"):Echo(1):await()
		t.expect(ok).toBe(true)
		t.expect(v).toBe(1)
	end, { timeout = 5, skip = Env.is151 }) -- skip only for 1.5.1 bugs, with a comment
end
```

## Add a bot

Write a module in `bots/` with `new`, `start`, `stop`, `waitIdle(seconds)` and `summary()`, then give it a role in `studio/Client.client.luau` (`startPhase`) and in `studio/ServerHarness/Scenarios.luau` (`roleFor`, `paramsFor`, `evaluate`).

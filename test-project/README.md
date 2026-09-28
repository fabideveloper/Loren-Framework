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
3. Read the REPORT in the **server** Output (entries start with `(LORENঌ - TEST)`); it ends with `RESULT: PASS|WARN|FAIL` (also saved to `TestConfig.LastResult`). `compare` prints a `COMPARE_JSON` line to diff runtimes.
   During `check`, red and yellow lines in the Output are expected (specs trigger errors on purpose); only the CHECK REPORT and its `RESULT` decide pass or fail.

The runtime is auto-detected: `LorenRuntime` = 2.0 (confirmed by `Loren.Version` once `Shared.Loren` loads), `LorenBridge`/`Shared.Loren` = 1.5.1, otherwise raw. Numbers are relative, since everything shares one machine.

## Layout

- `runner/LorenTest.luau`: the spec runner (`describe`/`it`/hooks/`expect`/`spy`, timeouts, yielding tests).
- `fixtures/`: plain 1.5.1-style Services and `TestController` (they must run unchanged on 2.0). `fixtures/v2/{Services,Controllers}` are registered on 2.x only.
- `bots/`: `CallSpammer`, `SignalWatcher`, `Burst`, `Exploiter`, `Soak` (plus the `CallKit` helper).
- `studio/`: `Server.server.luau`, `Client.client.luau`, `Harness/`, `ServerHarness/`. `raw/`: the fixture API on one RemoteEvent.
- `specs/`: `runner`, `studio/{server,client}`, `unit` and `v2` (2.0 only; `check` runs `unit` before the fixtures boot, then `Loren.Testing.Reset()`).
- Signal ordering safety net: `specs/unit/Ordering.spec.luau` (server outbox bytes per player, the server's in-frame order, ClientNet fed the server's frames) and the order round of the 2.0 `check` (`specs/v2/{server,client}/Order.spec.luau`, `fixtures/v2` `OrderService`/`OrderController`, steps in `studio/Harness/OrderPlan.luau`). Every client takes part at once: run `check` with `Clients` 2 and 3. `OrderService` fires its pre-HELLO probe only when `Scenario` is `check` or `all`.
- `specs/frozen/v2/`: a frozen copy of the runtime's Schema/Codec interpreter (`ServerStorage.LorenTest.Frozen.v2`), the reference for the phase-2 differential fuzz; `specs/unit/Frozen.spec.luau` compares the runtime against it. Never edit it; a later wire version gets its own folder.

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

## Bench place

`bench.project.json` builds a separate place that measures Loren's Signals and ClientEvents against BlinkBlox, Blink, ByteNet and BridgeNet2 (vendored in `bench/libs/`, each with its `LICENSE` and `PROVENANCE.md`).

1. `rojo build bench.project.json -o LorenBench.rbxl`, then open `LorenBench.rbxl` in Studio.
2. Set the attributes on `ReplicatedStorage.TestConfig`: `Scenario` = `bench`, `Library` = `all` (or `loren`, `blinkblox`, `blink`, `bytenet`, `bridgenet2`), `Payload` = `all` (6 core), `extra`, a payload name or a comma-separated list (`entity100,c2s1000`), `Seconds` (1-60), `Runs` (1-15), `Warmup` (0-10 s).
3. Set `Clients` to the number of Studio clients you start (1, then 3). `0` (auto) works too, but a client that joins late makes the whole run INVALID.
4. **Test > Clients and Servers**: 1 client, then 3 (in Play solo, BridgeNet2 is n/a if the player joined before the server script ran). Any client FPS works: clients fire C->S on a fixed 60 Hz tick, and a C->S run is INVALID only if a client holds fewer than 57 ticks/s. The defaults take about 14 min.
5. Read the server Output: a table per payload, then the REPORT, one `BENCH_JSON` line per row, the SUMMARY and `RESULT: DONE|INVALID` (also in `TestConfig.LastResult`).

**Quick mode (step checkpoints):** `Library` = `loren` runs only the `loren` and `loren-untyped` rows, about 5 min with the other defaults. The start banner says QUICK MODE. All five libraries still load, as in a full run, so compare its Loren rows with the baseline's (the other libraries' rows don't change between steps). The baseline must come from the same harness version (`BENCH_JSON` field `v`).

KB/s is computed (B/f x sender frames per second): Stats kbps reads 0 on loopback. sHBwork (`Stats.HeartbeatTimeMs`) is engine-wide and not ranked; whether a library's higher value is its own work is unproven, so compare it with the idle library work line (which brackets deferred work too).

If Studio has `LorenBench.rbxl` open (a `LorenBench.rbxl.lock` exists) when you rebuild it, close it there **without saving** and reopen it, or Studio's save overwrites the new harness. Every `BENCH_JSON` line carries the harness version (`"v":2` today).

Layout: `bench/BenchServer.server.luau`, `bench/BenchClient.client.luau`, `bench/shared/` (Config, Payloads, Plan, Probe, Recv, `Adapters/`), `bench/server/` (Runner, Table), `bench/services/LorenBench.luau`. Compare numbers only within one session: everything shares one machine.

## Add a bot

Write a module in `bots/` with `new`, `start`, `stop`, `waitIdle(seconds)` and `summary()`, then give it a role in `studio/Client.client.luau` (`startPhase`) and in `studio/ServerHarness/Scenarios.luau` (`roleFor`, `paramsFor`, `evaluate`).

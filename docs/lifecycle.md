---
sidebar_position: 4
title: Lifecycle
---

# The Loren Lifecycle

Every Service and Controller moves through the same, predictable boot sequence. Understanding the order is the key to avoiding race conditions.

## The two hooks

Each module may define two optional methods:

| Hook            | Timing       | Runs                                              |
| :-------------- | :----------- | :------------------------------------------------ |
| `LorenIgnite()` | Synchronous  | Sequentially, on **every** module, before any `LorenBurn`. |
| `LorenBurn()`   | Asynchronous | Spawned in parallel (`task.spawn`) after **all** modules have ignited. |

```lua
function MyService:LorenIgnite()
    -- Set up your own state. Do NOT touch other modules yet.
    self.points = {}
end

function MyService:LorenBurn()
    -- Everything is ignited now. Safe to use dependencies, connect events.
end
```

## The boot order

When you call `Loren:SetOnFire()`, the framework runs these phases in order:

1. **Registration** — `AddServices` / `AddControllers` have already `require`d each ModuleScript into the registry.
2. **Bridge setup** — the server creates the `LorenBridge` (RemoteEvent) and `LorenHandshake` (RemoteFunction) and assigns numeric IDs to every service, client method, and signal. The client waits for the bridge, then invokes the handshake to receive those ID maps.
3. **Dependency resolution** — for every module with a `Dependencies` array, Loren resolves each name and replaces the array with a table of live references. A missing name rejects the whole boot (see [Error Handling](./advanced/limits.md)).
4. **Listeners** — the network listeners are connected.
5. **Ignite** — `LorenIgnite()` is called on every module, one after another.
6. **Burn** — `LorenBurn()` is `task.spawn`-ed on every module.

`SetOnFire()` returns a Promise that resolves once every module has been ignited and burned.

```lua
Loren.AddServices(script.Services)
Loren:SetOnFire():andThen(function()
    print("The heart is burning.")
end)
```

:::caution Never use dependencies during Ignite
Because `LorenIgnite()` runs across all modules in sequence, a dependency may not have ignited yet when yours does. Reading its state during ignite is a race. Always interact with dependencies in `LorenBurn()`.
:::

:::info Ignite is synchronous — keep it fast
`LorenIgnite()` is **not** wrapped in `task.spawn`. If one module yields (e.g. `task.wait`, `WaitForChild`) inside ignite, it stalls the ignite phase for everything after it. Do blocking or yielding work in `LorenBurn()`.
:::

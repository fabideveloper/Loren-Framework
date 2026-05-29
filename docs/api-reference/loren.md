---
sidebar_position: 1
title: Loren
---

# Loren

The core runtime module, required from `ReplicatedStorage.Shared.Loren`. It is the same module on both boundaries; it detects which side it is running on.

## Properties

| Property        | Type      | Description                                  |
| :-------------- | :-------- | :------------------------------------------- |
| `Loren.IsServer` | `boolean` | `true` when running on the server.           |
| `Loren.IsClient` | `boolean` | `true` when running on the client.           |
| `Loren.IsOnFire` | `boolean` | `true` once `SetOnFire` has been called.     |

## Methods

### `Loren.AddServices(container)`

Registers Service ModuleScripts. **Server only** — ignored on the client and after ignition.

- **`container`**: `Instance | {Instance}` — a folder whose `ModuleScript` children are services, or an array of ModuleScripts.

```lua
Loren.AddServices(script.Services)
-- or
Loren.AddServices({ moduleA, moduleB })
```

### `Loren.AddControllers(container)`

Registers Controller ModuleScripts. **Client only** — ignored on the server and after ignition. Same signature as `AddServices`.

```lua
Loren.AddControllers(script.Controllers)
```

### `Loren:SetOnFire()`

Bootstraps the framework: sets up the bridge/handshake, resolves dependencies, then runs `LorenIgnite` and `LorenBurn` across every registered module. Safe to call once per boundary; calling again resolves immediately.

- **Returns**: `Promise` — resolves with the `Loren` table once the framework is burning.

```lua
Loren:SetOnFire()
    :andThen(function()
        print("Burning.")
    end)
    :catch(function(err)
        warn("Boot failed:", err) -- e.g. an unresolved dependency
    end)
```

See [Lifecycle](../lifecycle.md) for the exact phase order, and the [Signal](./signal.md) reference for cross-boundary events.

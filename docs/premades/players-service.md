---
sidebar_position: 1
title: PlayersService
---

# PlayersService (Premade)

Loren ships with a ready-to-inject data Service built around a ProfileService-style store. It is a **starting template** — inject it, then adapt it to your game.

```bash
loren inject service PlayersService
```

This copies `PlayersService.luau` into `src/server/Services/`.

## Prerequisites

The template expects two modules to exist in `ReplicatedStorage.Shared`:

- **`PlayersService`** — a ProfileService-style data store module (the template requires `ReplicatedStorage.Shared.PlayersService` and calls `GetProfileStore`).
- **`Promise`** — the Promise library shipped with Loren.

:::caution Wire your store first
The premade does not bundle a DataStore library. Add your ProfileService module to `src/shared` and confirm the require paths before relying on it.
:::

## What it does

On `LorenBurn`, it loads a profile for every player who joins, reconciles it against your template, and releases it on leave. Two methods read and write profile data by a **dotted path** (e.g. `"Currency.Coins"`).

## API

### `PlayersService:RequestData(player, path)`

Reads a value from the player's profile. Yields up to 10 seconds if the profile is still loading.

- **`player`**: `Player`
- **`path`**: `string` — dotted path into `profile.Data`.
- **Returns**: the value, or `nil` if not found.

```lua
local coins = PlayersService:RequestData(player, "Currency.Coins")
```

### `PlayersService:OverwriteData(player, path, data, returnPromise?)`

Writes a value at a dotted path.

- **`data`**: the value to set.
- **`returnPromise`**: `boolean?` — if `true`, returns a Promise instead of running synchronously.

```lua
PlayersService:OverwriteData(player, "Currency.Coins", 500)

-- Promise form:
PlayersService:OverwriteData(player, "Currency.Coins", 500, true)
    :andThen(function() print("saved") end)
    :catch(warn)
```

### `PlayersService.Client:RequestData(player, path)`

The client-facing wrapper. A Controller can request its own data; the call returns a Promise.

```lua
self.Dependencies.PlayersService:RequestData("Currency.Coins")
    :andThen(function(coins)
        print("I have", coins)
    end)
```

:::info Guard what the client can read
`RequestData` is exposed to clients. Add a `Middleware.RequestData` check to restrict which paths a player may read, so you never replicate sensitive fields. See [Middleware](../networking/middleware.md).
:::

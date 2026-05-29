---
sidebar_position: 2
title: Signal
---

# Signal

A network-optimized event for cross-boundary communication. You never construct a Signal yourself — declare its name in a Service's `Signals` array and Loren creates the object during ignition.

```lua
local PointsService = {
    Signals = {"PointsUpdated"}, -- becomes PointsService.Signals.PointsUpdated
}
```

The server fires; the client connects. The methods available differ by side.

## Server side

Access via `self.Signals.<Name>` in a top-level Service method (or `self.Server.Signals.<Name>` from inside a `Client` method).

### `Signal:Fire(player, ...)`

Sends the signal to **one** client.

- **`player`**: `Player` — the recipient.
- **`...`**: any arguments to deliver.

```lua
self.Signals.PointsUpdated:Fire(player, 150)
```

### `Signal:FireAll(...)`

Broadcasts the signal to **every** connected client.

```lua
self.Signals.PointsUpdated:FireAll(150)
```

## Client side

Access via the Service proxy: `self.Dependencies.PointsService.Signals.PointsUpdated`.

### `Signal:Connect(callback)`

Listens for the signal. Returns a connection object.

- **`callback`**: `(...any) -> ()` — receives the fired arguments.
- **Returns**: `{ Disconnect: () -> () }`.

```lua
local connection = PointsService.Signals.PointsUpdated:Connect(function(points)
    print("Points are now", points)
end)

-- Later:
connection.Disconnect()
```

### `Signal:Once(callback)`

Like `Connect`, but the listener automatically disconnects after the first fire. Also returns a connection object you can disconnect early.

```lua
PointsService.Signals.PointsUpdated:Once(function(points)
    print("First update only:", points)
end)
```

:::info One direction
Signals flow server → client only. To send data the other way, call a `Client` method on the Service (which returns a Promise). See [Controllers](../core-concepts/controllers.md).
:::

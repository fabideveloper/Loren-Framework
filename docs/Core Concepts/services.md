---
sidebar_position: 2
title: Services
---

# Services

Services act as the authoritative backend for your game. They handle data management, physics calculations, server-side validation, and state management. 

Every Service is a singleton, meaning only one instance of it exists per server.

## Defining a Service

A standard Service requires, at minimum, a table to hold its structure. The CLI `loren make service` command generates the following boilerplate:
```lua
local PlayerDataService = {
    Dependencies = {},
    Signals = {},
    Client = {},
    Middleware = {}
}

function PlayerDataService:LorenIgnite()
    -- Synchronous setup
end

function PlayerDataService:LorenBurn()
    -- Asynchronous execution
end

return PlayerDataService
```

## The Client Table

By default, everything inside a Service is strictly private to the server. To allow a Client Controller to interact with your Service, you must explicitly define functions inside the `Client` table.

The framework intercepts calls to these functions and automatically manages the underlying `RemoteEvent` data packing.

### Method Structure

When a Client invokes a Service method, the framework guarantees that the first argument received by the server is the `Player` object who made the request.
```lua
-- The client only passes 'itemId'
function PlayerDataService.Client:PurchaseItem(player, itemId)
    -- The server securely receives the player context
    local hasFunds = self.Server:CheckFunds(player)
    
    if hasFunds then
        return true, "Item purchased."
    else
        return false, "Insufficient funds."
    end
end
```

:::info The Server Context
Notice the use of `self.Server` in the example above. Methods executed within the `Client` table have their `self` context shifted. To access the top-level Service functions and variables, you must route through `self.Server`.
:::

## Firing Signals

Signals declared in the `Signals` table are automatically initialized by the framework. They provide a highly optimized alternative to standard `RemoteEvents`.
```lua
function PlayerDataService:AwardPoints(player, amount)
    -- Logic to award points...
    
    -- Notify the specific player
    self.Signals.PointsUpdated:Fire(player, amount)
    
    -- Or notify every connected client
    self.Signals.PointsUpdated:FireAll(amount)
end
```
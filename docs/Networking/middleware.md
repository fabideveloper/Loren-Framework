---
sidebar_position: 1
title: Middleware
---

# Middleware Security

Exposing methods to the client inherently introduces security risks. Malicious actors can execute client-side methods with fabricated arguments or spam network requests to degrade server performance.

Loren provides a built-in Middleware pipeline to sanitize and authorize network requests before they execute your core logic.

## How Middleware Intercepts

The Middleware table acts as a mirror to your Client table. If a function in the `Middleware` table shares the exact name as a function in the `Client` table, Loren will route the incoming request to the Middleware first.

The Middleware function must return a boolean. If it returns `true`, the pipeline proceeds to the Client method. If it returns `false`, the request is instantly dropped.

## Implementation Example

Consider a scenario where a player requests to drop an item from their inventory.
```lua
local InventoryService = {
    Client = {},
    Middleware = {}
}

-- The Validation Layer
function InventoryService.Middleware:DropItem(player, itemName, amount)
    -- Prevent exploiter payload manipulation
    if type(itemName) ~= "string" or type(amount) ~= "number" then
        return false, "Invalid payload types."
    end

    -- Prevent integer underflow attacks
    if amount <= 0 then
        return false, "Amount must be strictly positive."
    end

    -- Rate limiting or specific state checks
    if player:GetAttribute("IsTrading") then
        return false, "Cannot drop items while trading."
    end

    return true
end

-- The Execution Layer
function InventoryService.Client:DropItem(player, itemName, amount)
    -- This logic only executes if the Middleware returned true.
    -- We can safely trust the types and bounds of our arguments.
    self.Server:RemoveFromInventory(player, itemName, amount)
    return true
end
```

## Built-In Protections

If a Middleware function returns `false` along with a string message (e.g., `return false, "Denied"`), Loren will automatically route that message back to the client and reject the Controller's Promise with that exact string, allowing for clean UI error handling.

Furthermore, Loren natively enforces a global limit of 50 requests per second per player. Exceeding this limit drops all subsequent packets at the buffer level, ensuring your server's processing threads are never overwhelmed.
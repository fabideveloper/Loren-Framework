---
sidebar_position: 3
title: Controllers
---

# Controllers

Controllers are singleton modules that run exclusively on the Client. They manage user input, UI interactions, and client-side visual effects.

## Cross-Boundary Dependency Injection

Controllers have the unique ability to declare **Services** as dependencies. When you do this, Loren provides a proxy object that perfectly mimics the server's `Client` table and `Signals`.
```lua
local UIController = {
    Dependencies = {"PointsService"}
}

function UIController:LorenIgnite()
    -- Store the Service proxy for easy access
    self.PointsService = self.Dependencies.PointsService
end
```

## Calling Server Methods

When a Controller calls a Service method, the framework executes a network request. To prevent yielding the main thread, all cross-boundary calls automatically return a **Promise**.

:::caution Client Timeouts
If the server drops the request or fails to respond within 10 seconds, Loren will automatically reject the Promise to prevent client memory leaks.
:::
```lua
function UIController:LorenBurn()
    -- Request data from the server
    self.PointsService:GetCalculatedPoints(50)
        :andThen(function(result)
            print("Server calculation complete. Result:", result) 
        end)
        :catch(function(errorMessage)
            warn("The request failed or was denied:", errorMessage)
        end)
end
```

## Listening to Signals

Controllers can connect to Signals broadcasted by the server. 

```lua
function UIController:LorenBurn()
    -- Standard persistent connection
    self.PointsService.Signals.PointsUpdated:Connect(function(newPoints)
        print("Received updated points:", newPoints)
    end)

    -- One-time connection (automatically disconnects after firing)
    self.PointsService.Signals.PointsUpdated:Once(function(newPoints)
        print("This will only print the very first time points update.")
    end)
end
```
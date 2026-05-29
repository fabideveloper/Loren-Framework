---
sidebar_position: 1
title: Dependency Injection
---

# Dependency Injection

At the heart of the Loren Framework is a powerful Dependency Injection (DI) engine. Understanding how this engine resolves modules is critical to building scalable games.

## The Problem with Require

In standard Roblox development, scripts rely on absolute paths to require other modules (e.g., `require(game.ServerScriptService.Modules.Data.DataService)`). As a project grows, moving a single folder can break dozens of scripts. Furthermore, managing the initialization order of these modules manually often leads to infinite yield errors or race conditions.

## The Loren Solution

Loren abstracts the file system entirely. Instead of searching for file paths, you explicitly declare which modules a Service or Controller relies on using the `Dependencies` array.
```lua
local StoreService = {
    -- We declare that we need the DatabaseService to function.
    -- We do not care where it is located in the file tree.
    Dependencies = {"DatabaseService"}
}
```

When you call `Loren:SetOnFire()`, the framework reads all registered modules, resolves their requested dependencies by name, and injects a reference directly into the module's `Dependencies` table.

## Accessing Dependencies

Once the framework has resolved a dependency, you can access it via `self.Dependencies.ModuleName`. 

:::caution Initialization Order
Dependencies are injected during the framework's internal resolution phase. However, you should never call methods on a dependency inside of `LorenIgnite()`, as there is no guarantee that the dependency itself has finished its own ignite phase. 

Always interact with dependencies inside of `LorenBurn()`.
:::
```lua
function StoreService:LorenBurn()
    -- Safely access the resolved dependency
    local DatabaseService = self.Dependencies.DatabaseService

    -- We are now safe to call its methods
    local playerData = DatabaseService:GetPlayerData(somePlayer)
end
```

## Cross-Boundary Injection

The most powerful feature of Loren's DI system is that Controllers (Client) can declare Services (Server) as dependencies. The framework will automatically generate a localized proxy object containing the Service's `Client` methods and `Signals`, allowing for seamless cross-boundary communication.
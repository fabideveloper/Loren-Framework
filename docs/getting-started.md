---
sidebar_position: 2
title: Getting Started
---

# Getting Started

This guide will walk you through installing the CLI and bootstrapping your first Loren environment.

## Installation

Loren is distributed as a Node.js package. To install it globally on your system, open your terminal and run:
```bash
npm install -g loren-framework
```

:::info System Permissions
Depending on your operating system, you may need to run this command as an Administrator (Windows) or prefix it with `sudo` (Mac/Linux).
:::

## Initializing a Project

Navigate to your desired workspace folder in your terminal and run the initialization command:
```bash
loren init MyNewGame
```

You will be prompted to select your preferred synchronization tool (Rojo or Argon). The CLI will automatically scaffold the directory structure, generate your `aftman.toml`, configure your VS Code Luau-LSP settings, and create your initial sourcemap.

## Bootstrapping the Framework

To start the framework in your Roblox environment, you must ignite it on both the server and the client.

**Server (`src/server/init.server.luau`):**
```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

-- Register all Server Modules
Loren.AddServices(script.Parent.Services)

-- Ignite the framework
Loren:SetOnFire()
```

**Client (`src/client/init.client.luau`):**
```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

-- Register all Client Modules
Loren.AddControllers(script.Parent.Controllers)

-- Ignite the framework
Loren:SetOnFire()
```

:::tip Promise Resolution
`Loren:SetOnFire()` returns a Promise. This resolves only when every registered Service and Controller has successfully completed its initialization phase.
:::
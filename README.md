# LOREN-FRAMEWORK (v1.4.0)
> "Burning like a beating heart."

Loren is a CLI-driven, lightweight Roblox framework designed to eliminate pathing headaches, automate VS Code environments, and provide a clean, predictable lifecycle for your game logic.

---

## CLI Commands

| Command | Description |
| :--- | :--- |
| `loren init <name>` | Scaffolds a new project with auto-configured VS Code settings and sourcemaps. |
| `loren add <user/repo>` | Clones a GitHub module into `loren_packages` and updates autocomplete instantly. |
| `loren make <type> <name>` | Forges a new service or controller with full v1.2.4 boilerplate. |
| `loren inject <type> <name>` | Injects a pre-built module from your loren_premade folder into your active source code. |
| `loren refresh` | Manually refresh the Rojo / Argon sourcemap to update VS Code IntelliSense (in case you added stuff outside of loren) |
| `loren ignite` | Calls `rojo serve` / `argon serve` automatically |
| `loren migrate` | Migrate the current project between Rojo and Argon |


---

## Core Architecture

Loren is built on a Dependency Injection (DI) system. You never have to manually require() your internal modules; simply list their names in the Dependencies table, and Loren resolves them automatically during the boot sequence.

### Module Structure
A simple structure example:

```lua
-- a Simple service
local Service = { 
    Dependencies = {"AnotherService"}; -- any service you want
    Client = { };
    Signals = {"SendData"};
    Middleware = { 
        GetDataMultiplied = function(_, multiplier : number) -- check if multiplier is postiive before sending data back to the player
            return multiplier > 0
        end
    };
}

-- Init
function Service:LorenIgnite()
    self.someData = "I am data"
end

function Service.Client:GetDataMultiplied(player : Player, multiplier : number) -- Returns a promise
    return self.Server.someData
end

function Service:LorenBurn()
    -- Fire a signal to everyone
    self.Signals.SendData:FireAll(self.someData)
end

-- a Simple Controller
local Controller = {
    Dependencies = {"AnotherController", "Service"}; -- any controller/service you want. We require the previous service
}

function Controller:LorenIgnite()
    print("I am ignited!")
end

function Controller:LorenBurn()
    -- Pull the Proxy from our resolved dependencies
    local PointsService = self.Dependencies.Service

    -- Calling a Method (Returns a Promise)
    PointsService:GetDataMultiplied(10):andThen(function(result)
        print("Server says:", result)
    end):catch(warn)

    -- Connecting to a Signal
    PointsService.Signals.SendData:Connect(function(data)
        print("Received Signal Data:", data)
    end)
end

-- Bootstrapping
-- Getting the framework running is incredibly simple:
local Loren = require("path to loren")

Loren.AddServices("path to services") / Loren.AddControllers("path to controllers")
Loren:SetOnFire()
```

-> Note on v1.0.0: In this current version, Controllers cannot yet access Services directly. This cross-boundary communication is slated for a future update.

->  Note on v1.1.0: Cross-boundary communication is now fully operational. Controllers can include Services in their dependencies to access the binary bridge and call server-side logic via Promises.

-> Note on v1.2.0: The CLI has been completely overhauled for a zero-friction developer experience. Toolchain initialization (Aftman, Rojo, and VS Code settings) is now fully automated during `loren init`, and you can now use `loren inject` to instantly drop your own reusable templates from `loren_premade` directly into your active game logic.

-> Note on v1.2.1: Bug fixes and security changes

-> Note on v1.2.2: Added `loren refresh` and remove .import from Loren

-> Note on v1.2.3: All signals are now nested inside the "Signals" Table for services and controllers

-> Note on v1.2.4: Fixed fatal bug where signals could only transfer 1 argument a time.

-> Note on v1.3.0: Added :Once to signals, improved the buffer pool q (removed old caching), added client call timeout warn and improved security. *fixed bugs : promises could only transfer 1 argument at a time.

->Note on v1.4.0: Fixed old premade PlayersService, added support for argon and a command to migrate from argon to rojo and viceversa. update the init command.

### Documentation
Full API references, including the binary protocol specifications and middleware implementation guides, are available in the project's documentation folder. Keep your logic tight, your network clean, and keep the heart burning.

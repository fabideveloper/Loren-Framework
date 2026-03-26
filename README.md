# LOREN-FRAMEWORK (v1.0.0)
> "Burning like a beating heart."

Loren is a CLI-driven, lightweight Roblox framework designed to eliminate pathing headaches, automate VS Code environments, and provide a clean, predictable lifecycle for your game logic.

---

## CLI Commands

| Command | Description |
| :--- | :--- |
| `loren init <name>` | Scaffolds a new project with auto-configured VS Code settings and sourcemaps. |
| `loren add <user/repo>` | Clones a GitHub module into loren_packages and updates autocomplete instantly. |
| `loren make <type> <name> [blank]` | Creates a new service or controller. Specify 'blank' to generate the default boilerplate. |

---

## Core Architecture

Loren uses a Dependency Injection system. You don't need to manually require() your internal modules; simply list them in the Dependencies table, and Loren handles the resolution.

### Module Structure
```lua
local TestController = {
    -- List the names of the modules you need here
    Dependencies = {"TestController2"} 
}

-- Phase 1: Ignition (Setup variables & logic)
function TestController:LorenIgnite()
    local buddy = self.Dependencies.TestController2
    print("Link established with:", buddy)
end

-- Phase 2: Burn (Runs in a separate thread)
function TestController:LorenBurn()
    print("Loren is burning!")
end

return TestController
```
Note on v1.0.0: In this current version, Controllers cannot yet access Services directly. This cross-boundary communication is slated for a future update.

### Documentation
Full documentation, including advanced networking, API references, and cross-boundary communication, will be released in later versions. For now, keep it simple, keep it light, and keep it burning.

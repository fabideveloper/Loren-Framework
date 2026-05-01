---
sidebar_position: 5
title: CLI Reference
---

# Command Line Interface (CLI)

The Loren CLI (`loren-framework`) is the command center for your development workflow. It automates environment setup, generates boilerplate code, and manages your sync servers.

:::info Auto-Updater
The CLI actively monitors the npm registry. If a new version of the Loren Framework is released, you will receive a notification in your terminal upon running any command, prompting you to update.
:::

---

## Project Setup

Commands used to create and configure your workspace.

### `loren init`
Scaffolds a completely new Loren project directory.
```bash
loren init MyNewGame
```

* **`<name>`** (Required): The name of the folder and project to be generated.

**Behavior:**
* Checks if the directory already exists to prevent accidental overwrites.
* Prompts you to select your preferred sync tool (Rojo or Argon).
* Generates your `aftman.toml` file.
* Configures `.vscode/settings.json` for optimal Luau-LSP autocomplete.
* Generates an initial `sourcemap.json`.

### `loren migrate`
Automates the migration of your project toolchain between Rojo and Argon.
```bash
loren migrate
```

:::danger Use Version Control
This command actively rewrites your `aftman.toml` and `.vscode/settings.json` files. We strongly recommend ensuring your working tree is clean and committed to Git before running this command in case you wish to revert the changes.
:::

**Behavior:**
* Detects your currently installed tool and prepares to swap to the alternative.
* Prompts for user confirmation before proceeding.
* Updates Aftman dependencies and installs the new tool globally.
* Reconfigures VS Code autogenerate behavior to match the new tool.

---

## Generators

Commands designed to speed up your active development by eliminating boilerplate typing.

### `loren make`
Forges a new module with the standard Loren lifecycle boilerplate.
```bash
loren make service PlayerData
loren make controller UIHandler
```

* **`<type>`** (Required): Must be either `service` or `controller`.
* **`<name>`** (Required): The PascalCase name of the file to be created.

:::tip Auto-Refreshing
Running `loren make` automatically triggers a background sourcemap refresh. Your new module will instantly appear in your VS Code autocomplete suggestions without any extra steps.
:::

### `loren inject`
Injects a pre-built module from your local templates folder into your active source tree.
```bash
loren inject shared Logger
```

* **`<type>`** (Required): Must be `service`, `controller`, or `shared`.
* **`<name>`** (Required): The exact name of the file or folder inside your `loren_premade` directory.

**Behavior:**
* Scans `loren_premade/<type>` for the specified file or directory.
* Copies the template cleanly into `src/<type>`.
* Fails safely if the destination already contains a module with that name.

---

## Package Management

### `loren add`
Downloads a module repository directly from GitHub into your project.
```bash
# Standard installation
loren add evaera/roblox-lua-promise

# Installation with a custom folder alias
loren add Sleitnick/Signal LorenSignal
```

* **`<user/repo>`** (Required): The target GitHub repository path.
* **`[alias]`** (Optional): A custom name for the downloaded folder. 

:::info Default Naming
If you do not provide an `[alias]`, Loren will attempt to parse a clean name automatically (e.g., stripping out common prefixes like `roblox-lua-`). The package will be placed inside the `loren_packages` directory.
:::

---

## Synchronization

### `loren ignite`
Boots your local synchronization server.
```bash
loren ignite
```

**Behavior:**
* Scans your project configuration to detect whether you are using Rojo or Argon.
* Automatically executes the corresponding `serve` command attached to your terminal session.

### `loren refresh`
Forces a manual regeneration of the `sourcemap.json` file.
```bash
loren refresh
```

:::caution When to use this
You only need to run this command if you manually add, delete, or rename Lua files outside of the `loren make` command. If your VS Code Luau-LSP suddenly stops providing autocomplete suggestions for new files, running `refresh` will restore it.
:::
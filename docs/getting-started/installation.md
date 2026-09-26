---
title: Installation
sidebar_label: Installation
sidebar_position: 1
slug: /getting-started
description: Install the Loren 2.0 beta CLI, a sync tool and the Studio plugin, then check your setup.
---

# Installation

```bash
npm i -g loren-framework@next
loren --version
```

That installs the `loren` command. You need [Node.js](https://nodejs.org/) 18 or newer. `loren --version` should
print `2.0.0-beta.1`.

:::info[Beta]
Loren 2.0 is in beta, so it's published on npm's `next` tag. The default tag, `latest`, is still 1.5.1, which means
`npm i -g loren-framework` without `@next` installs 1.5.1. The beta CLI already adds `@next` to its own install hints.
Try the beta on a project you can afford to break.
:::

## Pick a sync tool

A sync tool copies your files from disk into Studio. Loren works with three:

| Tool | What you install | Good if |
|---|---|---|
| **Rojo** | Rokit (it installs Rojo for you) and the Rojo Studio plugin | You want the most common setup. It's the default. |
| **Argon** | Rokit (it installs Argon for you) and the Argon Studio plugin | You already use Argon. |
| **Script Sync** | Nothing. It's built into Studio. | You don't want extra tools. Loren calls this option "None". |

You pick one when you run `loren init`. You can switch between Rojo and Argon later with `loren migrate`.

## Rojo or Argon: the toolchain

Loren installs Rojo or Argon for you through a **toolchain manager**, a small program that downloads the exact tool
version a project asks for. For a new project that has to be [Rokit](https://github.com/rojo-rbx/rokit). Install it
first, following its own instructions.

When you run `loren init`, Loren writes a `rokit.toml` that pins the tool version and runs `rokit install` in the new
project. Existing projects with an `aftman.toml` or `foreman.toml` keep working: Loren uses Aftman or Foreman there
if you have them, and Rokit reads those files too.

Once the tool is installed (`loren init` does that), install its Studio plugin. You do this once per computer:

```bash
rojo plugin install
# or
argon plugin install
```

## Script Sync: nothing to install

Script Sync is part of Studio. You don't need Rokit, Rojo, Argon or a plugin. For autocomplete in VS Code, you can
add the Luau Language Server extension and the "Luau Language Server Companion" Studio plugin, but Loren runs fine
without them.

## Check your setup

```bash
loren doctor
```

Outside a project, `doctor` checks Node and your toolchain manager:

```text
(LORENঌ) Node 22.14.0
(LORENঌ) Toolchain manager: rokit
(LORENঌ) No default.project.json here: skipped the project checks. Run loren doctor in a project root to check it.
```

Inside a project it also checks the sync tool, the runtime files and your middleware. See
[CLI](../cli-reference.md#loren-doctor) for everything it looks at.

## Going back to 1.5.1

```bash
npm i -g loren-framework@latest
```

That puts the 1.5.1 CLI back. It doesn't touch your projects. If you already upgraded a project, see
[Rolling back](./upgrading.md#rolling-back).

## Next

[Create a project](./new-project.md). Already on 1.5.1? Go to [Upgrading from 1.5.1](./upgrading.md) instead.

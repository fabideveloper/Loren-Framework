---
sidebar_position: 1
title: Introduction
---

# Introduction to Loren

Loren is a CLI-driven, lightweight Roblox framework designed to eliminate pathing headaches, automate workspace environments, and provide a clean, predictable lifecycle for your game logic.

## Philosophy

Building scalable games in Roblox often leads to complex, tangled architecture. Developers spend excessive time managing `RemoteEvents`, configuring toolchains, and manually requiring modules across client and server boundaries. 

Loren solves these problems through three core principles:

1. **Automated Environments:** The CLI handles the boilerplate. Whether you prefer Rojo or Argon, Loren configures your sync tools and VS Code workspace instantly.
2. **Dependency Injection:** You will never write a manual `require()` path for an internal module again. By declaring dependencies upfront, Loren ensures they are resolved and injected automatically.
3. **Optimized Networking:** Loren uses a custom, internally managed binary protocol. Cross-boundary communication is streamlined via Promises and network-optimized Signals, fully equipped with strict rate-limiting.

By abstracting the network and toolchain layers, Loren allows you to focus entirely on writing feature logic.
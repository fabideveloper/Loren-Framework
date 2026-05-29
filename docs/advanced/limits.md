---
sidebar_position: 2
title: Limits & Constraints
---

# Limits & Constraints

The binary protocol that makes Loren fast also imposes a few hard ceilings. None are configurable at runtime — design around them.

## Hard limits

| Limit                         | Value      | Source            | What happens if exceeded                                   |
| :---------------------------- | :--------- | :---------------- | :--------------------------------------------------------- |
| Requests per second, per player | **50**   | `RATE_LIMIT`      | Further requests that second are dropped; server warns once. |
| Arguments per call            | **20**     | `MAX_ARGUMENTS`   | The request is silently dropped before your method runs.   |
| Services per game             | **255**    | `u8` service id   | The 256th service cannot be addressed over the network.    |
| Client methods per service    | **255**    | `u8` method id    | Extra client methods are unreachable.                      |
| Signals per service           | **255**    | `u8` signal id    | Extra signals are unreachable.                             |
| In-flight request IDs         | **65535**  | `u16` request id  | IDs wrap around `1..65535`; only matters with tens of thousands of unresolved calls at once. |
| Call timeout                  | **10 s**   | client `task.delay` | The Promise rejects with `"(LORENঌ) Timeout"`.           |

## Why these exist

The [packet header](./how-it-works.md#the-packet-header) encodes IDs and the argument count in single bytes (`u8`, max 255) and the request id in two bytes (`u16`, max 65535). Keeping the header tiny is what lets Loren run every call through one `RemoteEvent` cheaply.

## Practical guidance

- **Batch arguments into a table** if you are anywhere near 20. One table counts as one argument.
- **Group related methods** under fewer services rather than spreading hundreds of micro-services.
- **Expect rejection** on the client. A call can fail from a timeout, a rate-limit drop, an argument-cap drop, or a middleware denial — always attach a `:catch`.

```lua
self.Dependencies.DataService:Get("coins")
    :andThen(function(value) -- ... end)
    :catch(function(err)
        warn("request failed:", err)
    end)
```

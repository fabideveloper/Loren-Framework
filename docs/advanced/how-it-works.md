---
sidebar_position: 1
title: How It Works
---

# How It Works: The Binary Bridge

Loren does not create a `RemoteEvent` per feature. The entire framework communicates over a **single** `RemoteEvent` plus one `RemoteFunction`, using a compact binary header. This page explains that protocol.

## The two instances

On ignition the server creates and parents to `ReplicatedStorage`:

- **`LorenBridge`** — a `RemoteEvent`. Every request, response, and signal travels through it.
- **`LorenHandshake`** — a `RemoteFunction`. Invoked once by each client at boot.

## The handshake

Strings are expensive to send on every call. So names are never sent over the wire — only small numeric IDs are.

At boot the server builds bidirectional maps:

- service name ↔ service id
- method name ↔ method id (per service)
- signal name ↔ signal id (per service)

The client invokes `LorenHandshake` once and receives all of these maps. From then on, both sides translate between names and IDs locally.

## The packet header

Every bridge message begins with a **5-byte buffer**:

| Byte(s) | Field          | Type   | Meaning                                  |
| :------ | :------------- | :----- | :--------------------------------------- |
| 0–1     | Request ID     | `u16`  | Correlates a response to its request.    |
| 2       | Service ID     | `u8`   | Which service.                           |
| 3       | Method ID      | `u8`   | Which client method (or signal id).      |
| 4       | Argument count | `u8`   | Number of arguments that follow.         |

The raw arguments follow the header, untouched.

## Request → response flow

```
Controller calls proxy:Method(args)
        │  (returns a Promise immediately)
        ▼
pack 5-byte header + args ──FireServer──▶ Server
                                          │ rate-limit check (50/s)
                                          │ validate header (len == 5)
                                          │ resolve service + method by id
                                          │ run Middleware[method] (if any)
                                          │ pcall Client[method](player, ...)
                                          ▼
Promise resolves/rejects ◀──FireClient(reqId, success, ...)
```

The response reuses the same `reqId` so the client can match it to the pending Promise. If middleware denies the call, the client receives `success = false` and the Promise rejects with the message string.

## Telling responses from signals

The client's single `OnClientEvent` handler distinguishes the two message kinds by the **type of the first argument**:

- **First arg is a `buffer`** → it is a **signal** broadcast. Loren reads the service/signal id and fires the matching listeners.
- **First arg is a number** → it is a **response**. Loren looks up that `reqId` in the pending-requests table and resolves or rejects it.

## Timeouts

When a request is sent, the client arms a 10-second `task.delay`. If no response arrives in time, the pending Promise is rejected with `"(LORENঌ) Timeout"` and its entry is cleaned up, so a dropped request can never leak memory.

See [Limits & Constraints](./limits.md) for the numeric ceilings this design implies.

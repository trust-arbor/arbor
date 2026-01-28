# Secure Channels for Internal Coordination

## Problem

Trust system uses Phoenix.PubSub for internal coordination (tier changes, trust events). Currently safe because agents can't subscribe to PubSub topics directly. But when agents gain introspection or the system distributes, trust events become sensitive:

- Which agents are frozen/under investigation
- Security violation patterns
- Tier change history

An autonomous agent with PubSub access could observe all of this.

## Proposed Solution

A `contracts/distributed/secure_channel.ex` abstraction:

```elixir
@callback publish_to_secure_channel(channel_id, message, encryption_opts) :: :ok
@callback subscribe_to_secure_channel(channel_id, handler, auth_opts) :: {:ok, sub_id}
```

Where `auth_opts` requires a capability token to subscribe — tying channel access into the security system.

## When to Build

Not now. Build when any of these become true:
1. Agents can subscribe to arbitrary PubSub topics
2. System is distributed across nodes
3. Agents gain introspection capabilities (e.g., autonomous tier)

## Context

From 2026-01-27 contracts strategy session. The trust system's internal PubSub is the first candidate for secure channels, but Signals bus would also benefit eventually for agent-to-agent encrypted comms.

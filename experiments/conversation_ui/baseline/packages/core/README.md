# ConversationKit

A provisional, dependency-free Elixir package for sharing conversation semantics
across independently implemented visual and speech interfaces. It is an isolated
experiment, not a published package or a production persistence layer.

An independent host imports it as `{:conversation_kit, path: "../core"}`. The
earlier `conversation-framework-spike-20260926` artifact contains the original
LiveView, Breeze, TermUI, and Hologram renderer experiments. This copy adds the
pure `ConversationKit.Snapshot` module for the [Arbor adapter](../adapter/README.md)
and the shared web/TUI experiment; the original event API is unchanged.

`Snapshot.project(messages, deliveries)` accepts normalized semantic records and
returns separate message/delivery blocks while discarding non-display fields.
It preserves transcript text without the original event API's 16,000-byte
limit, creates no message-to-command correlation, and always returns empty
speech. The host adapter validates its source records before calling this pure
projection. The original event reducer below retains its original contract,
limits, and speech descriptions; those do not apply to the Arbor adapter path.

```elixir
fixture = "../fixtures/v1/conversation.json" |> File.read!() |> JSON.decode!()
{:ok, state} =
  ConversationKit.replay(fixture["events"], ConversationKit.new(fixture["id"]))
projection = ConversationKit.project(state)

{:ok, intent} = ConversationKit.intent(state, "send", %{"text" => "Hello"})
# Host authenticates/admit/executes intent and returns authoritative events.
# Rendering projection or creating an intent does not execute any effect.
```

Run from this directory with the isolated toolchain wrapper:

```sh
../bin/mix test
../bin/mix format --check-formatted
```

The package has no dependency on Arbor, DASP, Phoenix, Breeze, TermUI, Hologram,
an audio engine, JSON codecs, processes, clocks, persistence, or application
configuration. Public state and event values are JSON-compatible maps. A source
boundary test checks this dependency and purity rule.

[The contract](../docs/core-contract.md) describes exact event shapes, state
transitions, intents, progress and speech behavior. The versioned JSON event
schema is in [priv/event.schema.json](priv/event.schema.json). Shape validation
is followed by lifecycle validation in the reducer. Schema `x-maxUtf8Bytes`
records an additional UTF-8 byte limit; plain JSON Schema's `maxLength` counts
characters rather than bytes.

The [portable fixtures](../fixtures/manifest.json) include completed, pending and
uncertain commands; tool and approval lifecycles; duplicate replay; and 43 saved
updates imported from the preceding DASP host-crash experiment. A regression
compares this implementation's messages and command outcomes with that run's
actual final authoritative view.

The fixture schema has an optional independent Ajv development check:
`node ../fixtures/check-schema.mjs` from this directory. It reuses Ajv from the
preceding preserved DASP experiment's locked TypeScript client installation at
`../../dasp-session-experiment-20260926/upstream/clients/typescript/node_modules`.
If that installation is absent, restore that experiment's locked dependencies
before running this optional check. Ajv is not a ConversationKit dependency, and
the core's Mix test suite requires neither Node nor the previous experiment.
The checked-in fixture JSON and baseline source snapshots are self-contained.
`fixtures/generate.py` is an optional regeneration tool and additionally requires
the original DASP report named in its source; ordinary tests do not regenerate or
read that external report.

Scope limits are intentional: the core doesn't execute or authorize work, store
checkpoints, provide replay transport, classify secret content, play speech or
prevent duplicate audio. Its speech output describes eligible content with
stable IDs. Device playback policy remains separate. It keeps full duplicate
evidence and appends lists, adequate for a bounded spike but not a large-history
performance or retention design. Consume imported state by replaying events;
arbitrary external checkpoint maps are not a supported input.

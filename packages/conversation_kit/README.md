# ConversationKit

An independent, dependency-free Elixir library for sharing conversation semantics
across visual and voice interfaces. Arbor consumes it through a separate
[adapter](../conversation_kit_arbor/README.md). Other hosts can normalize their
own records into the same semantic projection or supply authoritative events to
the reducer. Neither API executes work or grants permission.

The name and public release are provisional. This maintained source package is
versioned `0.1.0-dev` and is not published. Consumers in this repository use:

```elixir
{:conversation_kit, path: "../../packages/conversation_kit"}
```

`ConversationKit.Snapshot.project(messages, deliveries)` returns separate message
and delivery blocks and discards non-display fields. Hosts validate source
records before projecting them. A completed delivery is never a fabricated
assistant transcript entry. History produces no speech playback effects.

`ConversationKit.Controls` validates a disposable, bounded activity and human
interaction observation. `replace/2` replaces the entire observation; `project/1`
produces display blocks with separate delivery, execution and cancellation facts,
and no speech. `intent/2` checks an exact currently pending command or prompt and
returns request data without changing state. Ordinary choices use choice IDs;
protected approvals use a separate decision route. Hosts retain all authority
and suppress controls while an operation is in flight. Read the [controls
contract](CONTRACT.md#bounded-controls-observation-2026-10-03) before normalizing
host records into this API.

The original event reducer supports message, command, tool, approval and passive
notice lifecycles. Its intents describe requests for the host to authenticate and
execute. Speech descriptions have stable IDs; device ownership, interruption and
at-most-once playback remain modality responsibilities.

```elixir
fixture = "test/fixtures/v1/conversation.json" |> File.read!() |> JSON.decode!()
{:ok, state} = ConversationKit.replay(fixture["events"], ConversationKit.new(fixture["id"]))
projection = ConversationKit.project(state)
{:ok, intent} = ConversationKit.intent(state, "send", %{"text" => "Hello"})
```

Read the [event contract](CONTRACT.md) and [schema](priv/event.schema.json).
The [shared feature recipe](FEATURE_RECIPE.md) shows how web and terminal
interfaces reuse draft decisions while retaining their native input controls.
Fixtures and the earlier reducer used by extension regressions are bundled under
`test/fixtures`; tests require no previous experiment, network or Node install.
From this directory, use the repository’s pinned wrapper:

```sh
../../bin/mix test
../../bin/mix compile --warnings-as-errors
../../bin/mix format --check-formatted
```

The pure source boundary is enforced in tests. There are no Arbor, renderer,
audio, persistence, process, clock or application-configuration dependencies.
Event replay retains its full validated state and duplicate evidence; it is not
an unlimited client-cache implementation. Arbor’s native interfaces use bounded
host windows through the adapter instead of replaying the complete transcript.
The retained comparison under `experiments/conversation_ui` remains immutable
historical evidence, separate from these maintained packages.

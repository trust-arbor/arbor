# arbor_commands

Side-effecting slash command implementations.

The command FRAMEWORK (`Arbor.Common.CommandRouter`, `Arbor.Common.CommandIntake`,
`Arbor.Common.Command` behaviour) lives in `arbor_common` alongside the
pure-read commands that only inspect `Arbor.Contracts.Commands.Context`
(Help, Status, Tools, Trust, Memory, Session, Compact, Clear).

This app hosts commands that need cross-library calls — Session mutators,
agent lifecycle, etc. These compile-time-depend on `arbor_orchestrator`
and `arbor_agent` so the calls are direct (no runtime indirection, no
behaviour-injection ceremony).

## Discovery

`Arbor.Common.CommandRouter` discovers command modules at runtime via a
`:code.all_loaded()` scan for modules implementing `@behaviour
Arbor.Common.Command`. arbor_commands modules show up in that scan as
long as the umbrella's started (the standard `mix arbor.start` /
`iex -S mix` path loads everything).

## Commands

- `Arbor.Commands.Runtime` — `/runtime [arbor|acp]`. Calls
  `Arbor.Orchestrator.Session.set_runtime/2`.
- `Arbor.Commands.Model` — `/model [name] [runtime=...]`. Calls
  `Arbor.Orchestrator.Session.set_model/2` and optionally `set_runtime/2`.
- `Arbor.Commands.Start` — `/start <template>`. Calls
  `Arbor.Agent.Manager.start_or_resume/3`.

## Design

See `.arbor/decisions/2026-06-04-slash-commands-for-runtime-config.md`
for the slash-command-over-GUI architectural call and
`.arbor/roadmap/5-completed/runtime-provider-axis-split.md` for the
runtime axis context.

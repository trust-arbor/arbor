# Arbor Agent

Supervised agent lifecycle for Arbor. An agent is a cryptographic Ed25519
identity plus a `BranchSupervisor` (rest_for_one) hosting the APIAgent,
Executor, and Session.

Create agents via `Arbor.Agent.Lifecycle.create/2` or the `Arbor.Agent`
facade (`create_agent/2`, `start/4`, `stop/1`). Templates (`researcher`,
`scout`, and others in `Arbor.Agent.TemplateStore`) supply default
capabilities, goals, and character.

## Public surface

- `Arbor.Agent` — facade for lifecycle, lookup, and action dispatch
- `Arbor.Agent.Manager` — start / resume / stop running agents
- `Arbor.Agent.Lifecycle` — persist and create profiles
- `Arbor.Agent.APIAgent` — query a running agent process

This is an umbrella app (L7), not a standalone Hex package. It depends on
`arbor_kernel_runtime`, `arbor_security`, `arbor_memory`, `arbor_trust`,
`arbor_actions`, and related lower-level libraries.

## License

MIT

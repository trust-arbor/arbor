defmodule Arbor.Contracts.Feature do
  @moduledoc """
  Passive declarations for statically assembled first-party features.

  A declaration describes existing wiring. It does not start children, load
  configured producers, probe services, attest durability or grant authority.
  Startup admission and enforcement remain with their existing owners.

  `requires/0` names fixed-host or shared-feature prerequisites, never another
  profile pack. The initial `:core` declaration describes Kernel Runtime's
  existing fixed host. It does not classify that host as the optional Shared
  layer, reproduce Mix dependencies or prove a complete release closure.

  `children/1` receives complete owner-resolved settings and facts, including
  any real private reference already available to its caller. It derives actual
  child-specification maps, preserving the producer's provided keys and argument
  wrapping. Omitted optional fields stay omitted. A snapshot is not an arbitrary
  supplied child plan or start MFA. Missing facts remain unresolved outside this
  callback; malformed direct calls must fail without exposing their values.

  Full child maps and private arguments are internal. Reports use a separate safe
  projection. Catalogs and URI lists are declarations, not proof of ownership,
  successful registration, activation or authorization. Source metadata must keep
  physical producers, registering actors and nonexclusive references distinct.

  Discovery reads static metadata of applications already loaded in the release.
  An unloaded declaration remains unresolved; discovery must not load it merely
  to inspect its callbacks. A missing optional callback means undeclared, not a
  verified empty contribution. Health may explicitly remain unobserved.
  """

  @callback id() :: atom()
  @callback requires() :: [atom()]
  @callback children(config :: map()) :: [Supervisor.child_spec()]
  @callback action_modules() :: [module()]
  @callback graphs() :: [{String.t(), Path.t()}]
  @callback uri_prefixes() :: [String.t()]
  @callback routes() :: [term()]
  @callback commands() :: [module()]
  @callback health() :: map()

  @optional_callbacks graphs: 0, routes: 0, commands: 0
end

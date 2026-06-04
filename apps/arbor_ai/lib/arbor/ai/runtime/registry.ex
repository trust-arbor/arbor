defmodule Arbor.AI.Runtime.Registry do
  @moduledoc """
  Maps runtime atoms to `Arbor.AI.Runtime` behaviour implementations.

  Backed by Application env so operators can swap impls at boot without
  recompiling — useful for substituting `Arbor.AI.Runtime.Arbor` with a
  mock in tests or pinning a particular `Runtime.Acp` variant.

  ## Lookup semantics

  - `lookup(:arbor)` and `lookup(:acp)` are guaranteed to resolve to a
    real module — the built-in defaults ship with arbor_ai.
  - Unknown runtime atoms fall through to `Runtime.Arbor` rather than
    erroring. The rationale: the runtime axis is advisory until enough
    callers are migrated; an unmapped atom defaulting to the BEAM-native
    path matches what callers got before the registry existed.
  - Operators override by setting `config :arbor_ai, :runtime_registry,
    %{arbor: SomeModule, acp: SomeOtherModule}`.

  ## Why not persistent_term

  We considered persistent_term for O(1) lock-free lookup, but the
  Application-env shape keeps config in one place and Phase 2c isn't
  on the hot path (a turn dispatches once; the lookup happens once per
  turn). When and if dispatch frequency grows, a persistent_term cache
  in front of this lookup is a clean add.
  """

  alias Arbor.AI.Runtime

  @default_registry %{
    arbor: Arbor.AI.Runtime.Arbor,
    acp: Arbor.AI.Runtime.Acp
  }

  @doc """
  Return the module registered for `runtime_atom`. Falls through to
  `Arbor.AI.Runtime.Arbor` for unknown runtime atoms.
  """
  @spec lookup(atom()) :: module()
  def lookup(runtime_atom) when is_atom(runtime_atom) do
    registry()
    |> Map.get(runtime_atom, Arbor.AI.Runtime.Arbor)
  end

  @doc """
  Return the full registry map (operator-configured overlay on top of
  the built-in defaults). Useful for `mix arbor.doctor` to enumerate
  registered runtimes.
  """
  @spec all() :: %{atom() => module()}
  def all do
    registry()
  end

  @doc """
  Return the `%RuntimeProfile{}` for `runtime_atom`, or `:not_loaded`
  if the module hasn't compiled or doesn't implement the behaviour.
  """
  @spec profile(atom()) :: Arbor.Contracts.AI.RuntimeProfile.t() | :not_loaded
  def profile(runtime_atom) when is_atom(runtime_atom) do
    runtime_atom
    |> lookup()
    |> Runtime.profile_of()
  end

  defp registry do
    operator_overlay = Application.get_env(:arbor_ai, :runtime_registry, %{})
    Map.merge(@default_registry, operator_overlay)
  end
end

defmodule Arbor.Contracts.Handler.Registry do
  @moduledoc """
  Contract for registry instances built on RegistryBase.

  Defines the standard API that all Arbor registries expose.
  The actual implementation is provided by `use Arbor.Common.RegistryBase`
  in `arbor_common`.

  Registry entries are always serializable: `{name, module, metadata}`
  where name is a string, module is an atom, and metadata is a plain map.
  This enables future multi-node registry sync over BEAM distribution.
  """

  @type name :: String.t()
  @type entry :: {name(), module(), metadata :: map()}

  @doc "Register a module under the given name with optional metadata."
  @callback register(name(), module(), map()) :: :ok | {:error, term()}

  @doc "Remove a registration by name."
  @callback deregister(name()) :: :ok | {:error, :not_found}

  @doc "Resolve a name to its registered module."
  @callback resolve(name()) :: {:ok, module()} | {:error, :not_found}

  @doc "Resolve a name to its full entry (name, module, metadata)."
  @callback resolve_entry(name()) :: {:ok, entry()} | {:error, :not_found}

  @doc "List all registered entries."
  @callback list_all() :: [entry()]

  @doc "List entries that are currently available (passes available?/0 check)."
  @callback list_available() :: [entry()]

  @doc "Lock core registrations. After this, core names cannot be overwritten."
  @callback lock_core() :: :ok

  @doc "Check if core registrations are locked."
  @callback core_locked?() :: boolean()

  @doc "Snapshot current state for test isolation."
  @callback snapshot() :: term()

  @doc "Restore a previously captured snapshot."
  @callback restore(term()) :: :ok
end

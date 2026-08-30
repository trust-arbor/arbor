defmodule Arbor.Actions.Application do
  @moduledoc """
  Application supervisor for Arbor.Actions.

  Arbor.Actions provides Jido-compatible action modules for common operations
  like shell commands, file operations, and git operations.
  """

  use Application

  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Coding.WorkspaceRetentionDurableStore
  alias Arbor.Actions.Coding.ValidationResourceOwner
  alias Arbor.Actions.Config

  @impl true
  def start(_type, _args) do
    children = supervision_children()

    opts = [strategy: :one_for_one, name: Arbor.Actions.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Arbor.Actions.register_action_uri_prefixes()
        {:ok, pid}

      other ->
        other
    end
  end

  @doc """
  Child specs for the Actions supervisor.

  Production enables the node-restart retention journal by default. When
  `Config.workspace_retention_journal_enabled?/0` is false (test), the durable
  store is omitted and the registry receives `retention_journal: :disabled` so
  no process opens the operator home journal under `MIX_ENV=test`.
  """
  @spec supervision_children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def supervision_children do
    journal = Config.application_retention_journal()

    [
      # Registry for tracking action executions if needed
      {Registry, keys: :unique, name: Arbor.Actions.Registry}
    ] ++
      retention_store_children(journal) ++
      [
        ValidationResourceOwner.supervisor_child_spec(),
        # Coding workspace leases - monitored worktree lifecycle, independent of orchestrator.
        {WorkspaceLeaseRegistry, [retention_journal: journal]}
      ]
  end

  defp retention_store_children(:disabled), do: []

  defp retention_store_children({store_name, _backend}) when is_atom(store_name) do
    # Production store is named by module; never accept a caller path here.
    [{WorkspaceRetentionDurableStore, name: store_name}]
  end

  defp retention_store_children(_), do: []
end

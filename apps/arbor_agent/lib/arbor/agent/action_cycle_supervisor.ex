defmodule Arbor.Agent.ActionCycleSupervisor do
  @moduledoc """
  DynamicSupervisor for ActionCycleServer processes.

  Manages the lifecycle of per-agent action cycle servers.
  Each agent gets at most one ActionCycleServer, registered by agent_id.
  """

  use DynamicSupervisor

  alias Arbor.Agent.ActionCycleServer

  @registry Arbor.Agent.ActionCycleRegistry

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a new ActionCycleServer for an agent.
  """
  @spec start_server(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_server(agent_id, opts \\ []) do
    name = {:via, Registry, {@registry, agent_id}}

    with {:ok, child_opts, generated_bootstrap} <- prepare_child_opts(agent_id, opts) do
      child_opts = Keyword.merge(child_opts, agent_id: agent_id, name: name)

      case DynamicSupervisor.start_child(__MODULE__, {ActionCycleServer, child_opts}) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          if generated_bootstrap, do: close_bootstrap(child_opts)
          {:ok, pid}

        {:error, _reason} = error ->
          if generated_bootstrap, do: close_bootstrap(child_opts)
          error
      end
    end
  end

  @doc """
  Stop the ActionCycleServer for an agent.
  """
  @spec stop_server(String.t()) :: :ok | {:error, term()}
  def stop_server(agent_id) do
    case lookup(agent_id) do
      {:ok, pid} ->
        case ActionCycleServer.close_bootstrap(pid) do
          :ok -> DynamicSupervisor.terminate_child(__MODULE__, pid)
          {:error, reason} -> {:error, {:bootstrap_close_failed, reason}}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Get or start an ActionCycleServer for an agent.
  """
  @spec get_or_start_server(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def get_or_start_server(agent_id, opts \\ []) do
    case lookup(agent_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> start_server(agent_id, opts)
    end
  end

  @doc """
  Look up an ActionCycleServer by agent_id.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(agent_id) do
    case Registry.lookup(@registry, agent_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp prepare_child_opts(agent_id, opts) do
    cond do
      Keyword.has_key?(opts, :signing_authority_bootstrap) ->
        {:ok, opts, false}

      Keyword.has_key?(opts, :signer) ->
        # Explicit legacy compatibility for callers/tests that supply a
        # signer. Production callers must use the bootstrap path.
        {:ok, opts, false}

      true ->
        with {:ok, bootstrap} <-
               Arbor.Agent.Lifecycle.issue_signing_authority_bootstrap(
                 agent_id,
                 :action_cycle
               ) do
          {:ok, Keyword.put(opts, :signing_authority_bootstrap, bootstrap), true}
        end
    end
  end

  defp close_bootstrap(opts) do
    case Keyword.fetch(opts, :signing_authority_bootstrap) do
      {:ok, bootstrap} -> _ = Arbor.Security.close_signing_authority_bootstrap(bootstrap)
      :error -> :ok
    end
  end
end

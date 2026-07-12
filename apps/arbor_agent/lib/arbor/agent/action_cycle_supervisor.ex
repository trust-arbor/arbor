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

    child_opts =
      opts
      |> maybe_put_lifecycle_signer(agent_id)
      |> Keyword.merge(agent_id: agent_id, name: name)

    case DynamicSupervisor.start_child(__MODULE__, {ActionCycleServer, child_opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @doc """
  Stop the ActionCycleServer for an agent.
  """
  @spec stop_server(String.t()) :: :ok | {:error, :not_found}
  def stop_server(agent_id) do
    case lookup(agent_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

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

  # The supervisor may acquire the existing lifecycle signer for the child, but
  # never returns it or turns the scalar id into an Actions authority token.
  # ActionCycleServer cryptographically challenges the signer before retaining
  # it and every action still traverses the normal Trust/capability gate.
  defp maybe_put_lifecycle_signer(opts, agent_id) do
    if Keyword.has_key?(opts, :signer) do
      opts
    else
      case Arbor.Agent.Lifecycle.build_signer(agent_id) do
        {:ok, signer} -> Keyword.put(opts, :signer, signer)
        {:error, _reason} -> opts
      end
    end
  end
end

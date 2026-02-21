defmodule Arbor.Sandbox.ExecSupervisor do
  @moduledoc """
  DynamicSupervisor for ExecSession processes.

  Manages the lifecycle of per-agent code execution sandboxes.
  Sessions are registered by agent_id for lookup.
  """

  use DynamicSupervisor

  alias Arbor.Sandbox.ExecSession

  @registry Arbor.Sandbox.ExecRegistry

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a new ExecSession for an agent.

  ## Options

  Same as `ExecSession.start_link/1`.
  """
  @spec start_session(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(agent_id, opts \\ []) do
    name = {:via, Registry, {@registry, agent_id}}
    child_opts = Keyword.merge(opts, agent_id: agent_id, name: name)

    case DynamicSupervisor.start_child(__MODULE__, {ExecSession, child_opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @doc """
  Stop an ExecSession for an agent.
  """
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(agent_id) do
    case lookup(agent_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Get or start an ExecSession for an agent.

  Returns the existing session if one is running, otherwise starts a new one.
  """
  @spec get_or_start_session(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def get_or_start_session(agent_id, opts \\ []) do
    case lookup(agent_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> start_session(agent_id, opts)
    end
  end

  @doc """
  Look up an ExecSession by agent_id.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(agent_id) do
    case Registry.lookup(@registry, agent_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end
end

defmodule Arbor.Voice.SessionSupervisor do
  @moduledoc """
  Named `DynamicSupervisor` for temporary `Arbor.Voice.Session` children.

  Sessions register under the exact `{user_id, agent_id}` key in
  `Arbor.Voice.Registry`. Restart is `:temporary` so a normal stop or hard
  timeout does not auto-restart an untracked session.
  """

  @name __MODULE__

  @doc false
  def child_spec(_args) do
    %{
      id: @name,
      start:
        {DynamicSupervisor, :start_link,
         [[name: @name, strategy: :one_for_one, max_restarts: 100, max_seconds: 1]]},
      type: :supervisor
    }
  end

  @doc false
  @spec start_session(map()) :: {:ok, pid()} | {:error, term()}
  def start_session(config) when is_map(config) do
    child_spec = %{
      id: {Arbor.Voice.Session, config.session_key},
      start: {Arbor.Voice.Session, :start_link, [config]},
      restart: :temporary,
      type: :worker,
      shutdown: 30_000
    }

    case DynamicSupervisor.start_child(@name, child_spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:ok, pid, _info} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        {:error, :already_started}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

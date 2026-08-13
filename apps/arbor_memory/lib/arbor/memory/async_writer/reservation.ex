defmodule Arbor.Memory.AsyncWriter.Reservation do
  @moduledoc false

  @enforce_keys [:token, :worker, :owner, :agent_id]
  defstruct [:token, :worker, :owner, :agent_id]

  @opaque t :: %__MODULE__{
            token: binary(),
            worker: pid(),
            owner: pid(),
            agent_id: String.t()
          }

  @doc false
  @spec new(binary(), pid(), pid(), String.t()) :: t()
  def new(token, worker, owner, agent_id)
      when is_binary(token) and is_pid(worker) and is_pid(owner) and is_binary(agent_id) do
    %__MODULE__{token: token, worker: worker, owner: owner, agent_id: agent_id}
  end

  @doc false
  @spec worker(t()) :: pid()
  def worker(%__MODULE__{worker: worker}), do: worker

  @doc false
  @spec owner(t()) :: pid()
  def owner(%__MODULE__{owner: owner}), do: owner

  @doc false
  @spec token(t()) :: binary()
  def token(%__MODULE__{token: token}), do: token

  defimpl Inspect do
    def inspect(%{agent_id: agent_id}, _opts) do
      "#AsyncWriter.Reservation<agent=#{inspect(agent_id)} token=[REDACTED]>"
    end
  end
end

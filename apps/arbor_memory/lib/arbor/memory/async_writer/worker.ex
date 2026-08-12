defmodule Arbor.Memory.AsyncWriter.Worker do
  @moduledoc false

  use GenServer

  alias Arbor.Memory.AsyncWriter.Operation
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission

  @doc false
  def start_link(operation), do: GenServer.start_link(__MODULE__, operation)

  @doc false
  def child_spec(operation) do
    %{
      id: {:async_writer, System.unique_integer([:positive])},
      start: {__MODULE__, :start_link, [operation]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @impl true
  def init(operation) do
    case Operation.validate(operation) do
      :ok ->
        case MutationAdmission.acquire(Operation.agent_id(operation)) do
          {:ok, lease} ->
            {:ok, %{lease: lease, operation: operation}, {:continue, :run}}

          {:error, reason} ->
            {:stop, {:admission, reason}}
        end

      {:error, _reason} ->
        {:stop, {:admission, :invalid_request}}
    end
  end

  @impl true
  def handle_continue(:run, %{lease: lease, operation: operation} = state) do
    try do
      _ = perform(operation)
    after
      _ = MutationAdmission.release(lease)
    end

    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp perform({:persist, fields}) do
    MemoryStore.persist_confirmed(
      fields.namespace,
      fields.key,
      fields.data,
      fields.metadata
    )
  end

  defp perform({:embed, fields}) do
    MemoryStore.embed_confirmed(
      fields.agent_id,
      fields.namespace,
      fields.key,
      fields.content,
      fields.type,
      fields.taint
    )
  end
end

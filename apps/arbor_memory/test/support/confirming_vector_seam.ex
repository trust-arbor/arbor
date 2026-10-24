defmodule Arbor.Memory.Test.ConfirmingVectorSeam do
  @moduledoc false

  @behaviour Arbor.Memory.StrictVectorSeam

  @impl true
  def encode_operation(_input), do: {:error, :unsupported}

  @impl true
  def encode_batch(_inputs), do: {:error, :unsupported}

  @impl true
  def execute(_agent_id, _input, _opts \\ []), do: {:error, :unsupported}

  @impl true
  def reconcile(_agent_id, _input, _opts \\ []), do: {:error, :unsupported}

  @impl true
  def search(_agent_id, _vector, _opts \\ []), do: {:error, :unsupported}

  @impl true
  def fetch(_agent_id, _namespace, _key, _opts \\ []), do: {:error, :not_found}

  @impl true
  def list(_agent_id, _opts \\ []), do: {:ok, []}

  @impl true
  def destroy(_agent_id, _opts \\ []), do: :ok

  @spec install!() :: {:ok, term()} | :error
  def install! do
    previous = Application.fetch_env(:arbor_memory, :strict_vector_seam)
    Application.put_env(:arbor_memory, :strict_vector_seam, __MODULE__)
    previous
  end

  @spec restore({:ok, term()} | :error) :: :ok
  def restore({:ok, value}) do
    Application.put_env(:arbor_memory, :strict_vector_seam, value)
    :ok
  end

  def restore(:error) do
    Application.delete_env(:arbor_memory, :strict_vector_seam)
    :ok
  end
end

defmodule Arbor.Memory.AsyncWriterEmbedTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory.EmbeddingEvidence
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MemoryStoreIdentity

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B0"

  defmodule SuccessSeam do
    @moduledoc false

    def fetch(_agent_id, _namespace, _key, _opts), do: {:error, :not_found}

    def encode_operation(closed) do
      Process.put({__MODULE__, :last_closed}, closed)
      {:ok, {:op, closed}, %{}}
    end

    def execute(agent_id, {:op, closed}, _opts) do
      {:ok, receipt(agent_id, closed)}
    end

    def execute(agent_id, _operation, _opts) do
      {:ok,
       %{
         record: %{
           agent_id: agent_id,
           source_namespace: "async_writer",
           source_key: "unknown",
           id: "ms_unknown"
         }
       }}
    end

    def reconcile(_agent_id, _operation, _opts), do: {:error, :unavailable}
    def search(_agent_id, _vector, _opts), do: {:ok, []}
    def list(_agent_id, _opts), do: {:ok, []}
    def destroy(_agent_id, _opts), do: :ok

    defp receipt(agent_id, closed) do
      namespace =
        Map.get(closed, :source_namespace) || Map.get(closed, :namespace, "async_writer")

      key = Map.get(closed, :source_key) || Map.get(closed, :key, "unknown")

      %{
        record: %{
          agent_id: agent_id,
          source_namespace: namespace,
          source_key: key,
          id: MemoryStoreIdentity.row_id(agent_id, namespace, key)
        }
      }
    end
  end

  defmodule ConflictSeam do
    @moduledoc false
    def fetch(_agent_id, _namespace, _key, _opts), do: {:error, :not_found}
    def encode_operation(closed), do: {:ok, {:op, closed}, %{}}
    def execute(_agent_id, _operation, _opts), do: {:error, :conflict}
    def reconcile(_agent_id, _operation, _opts), do: {:error, :conflict}
    def search(_agent_id, _vector, _opts), do: {:ok, []}
    def list(_agent_id, _opts), do: {:ok, []}
    def destroy(_agent_id, _opts), do: :ok
  end

  defmodule UnavailableSeam do
    @moduledoc false
    def fetch(_agent_id, _namespace, _key, _opts), do: {:error, :unavailable}
    def encode_operation(_closed), do: {:error, :unavailable}
    def execute(_agent_id, _operation, _opts), do: {:error, :unavailable}
    def reconcile(_agent_id, _operation, _opts), do: {:error, :unavailable}
    def search(_agent_id, _vector, _opts), do: {:ok, []}
    def list(_agent_id, _opts), do: {:ok, []}
    def destroy(_agent_id, _opts), do: :ok
  end

  defmodule MalformedSeam do
    @moduledoc false
    def fetch(_agent_id, _namespace, _key, _opts), do: {:ok, :not_a_view}
    def encode_operation(_closed), do: :not_a_tuple
    def execute(_agent_id, _operation, _opts), do: :not_a_receipt
    def reconcile(_agent_id, _operation, _opts), do: :not_a_receipt
    def search(_agent_id, _vector, _opts), do: {:ok, []}
    def list(_agent_id, _opts), do: {:ok, []}
    def destroy(_agent_id, _opts), do: :ok
  end

  defmodule IndeterminateSeam do
    @moduledoc false
    def fetch(_agent_id, _namespace, _key, _opts), do: {:error, :not_found}
    def encode_operation(closed), do: {:ok, {:op, closed}, %{}}
    def execute(_agent_id, _operation, _opts), do: {:error, :indeterminate}
    def reconcile(_agent_id, _operation, _opts), do: {:ok, :absent}
    def search(_agent_id, _vector, _opts), do: {:ok, []}
    def list(_agent_id, _opts), do: {:ok, []}
    def destroy(_agent_id, _opts), do: :ok
  end

  defmodule ExceptionSeam do
    @moduledoc false
    def fetch(_agent_id, _namespace, _key, _opts), do: raise("forced embed exception")
    def encode_operation(_closed), do: {:ok, :op, %{}}
    def execute(_agent_id, _operation, _opts), do: {:ok, %{}}
    def reconcile(_agent_id, _operation, _opts), do: {:error, :unavailable}
    def search(_agent_id, _vector, _opts), do: {:ok, []}
    def list(_agent_id, _opts), do: {:ok, []}
    def destroy(_agent_id, _opts), do: :ok
  end

  defmodule ExitSeam do
    @moduledoc false
    def fetch(_agent_id, _namespace, _key, _opts), do: exit(:forced_embed_exit)
    def encode_operation(_closed), do: {:ok, :op, %{}}
    def execute(_agent_id, _operation, _opts), do: {:ok, %{}}
    def reconcile(_agent_id, _operation, _opts), do: {:error, :unavailable}
    def search(_agent_id, _vector, _opts), do: {:ok, []}
    def list(_agent_id, _opts), do: {:ok, []}
    def destroy(_agent_id, _opts), do: :ok
  end

  setup do
    original_seam = Application.get_env(:arbor_memory, :strict_vector_seam)

    on_exit(fn ->
      restore_memory_env(:strict_vector_seam, original_seam)
    end)

    :ok
  end

  test "embed_confirmed succeeds after provider evidence" do
    Application.put_env(:arbor_memory, :strict_vector_seam, SuccessSeam)

    assert {:ok, :acknowledged} =
             MemoryStore.embed_confirmed(
               "aw_embed_ok",
               "async_writer",
               "ok",
               "provider success content",
               "thought",
               nil
             )

    closed = Process.get({SuccessSeam, :last_closed})
    assert match?({:provider_model, _, _}, closed.model_evidence)
  end

  test "embed_confirmed keeps provider-to-local-hash fallback then writes" do
    Application.put_env(:arbor_memory, :strict_vector_seam, SuccessSeam)

    original_routing = Application.get_env(:arbor_ai, :embedding_routing)
    original_fallback = Application.get_env(:arbor_ai, :embedding_test_fallback)

    Application.put_env(:arbor_ai, :embedding_routing, %{
      providers: [],
      fallback_to_cloud: false,
      preferred: :local
    })

    Application.put_env(:arbor_ai, :embedding_test_fallback, false)

    on_exit(fn ->
      restore_ai_env(:embedding_routing, original_routing)
      restore_ai_env(:embedding_test_fallback, original_fallback)
    end)

    assert {:ok, :acknowledged} =
             MemoryStore.embed_confirmed(
               "aw_embed_fallback",
               "async_writer",
               "fallback",
               "fallback content",
               "thought",
               nil
             )

    closed = Process.get({SuccessSeam, :last_closed})
    assert closed.model_evidence == {:model_id, EmbeddingEvidence.local_hash_model_id()}
  end

  test "embed_confirmed propagates a failed strict-vector write" do
    Application.put_env(:arbor_memory, :strict_vector_seam, ConflictSeam)

    assert {:error, :conflict} =
             MemoryStore.embed_confirmed(
               "aw_embed_conflict",
               "async_writer",
               "conflict",
               "conflict content",
               "thought",
               nil
             )
  end

  test "embed_confirmed returns unavailable" do
    Application.put_env(:arbor_memory, :strict_vector_seam, UnavailableSeam)

    assert {:error, :unavailable} =
             MemoryStore.embed_confirmed(
               "aw_embed_unavail",
               "async_writer",
               "unavail",
               "unavailable content",
               "thought",
               nil
             )
  end

  test "embed_confirmed returns malformed" do
    Application.put_env(:arbor_memory, :strict_vector_seam, MalformedSeam)

    assert {:error, :malformed} =
             MemoryStore.embed_confirmed(
               "aw_embed_malformed",
               "async_writer",
               "malformed",
               "malformed content",
               "thought",
               nil
             )
  end

  test "embed_confirmed returns indeterminate" do
    Application.put_env(:arbor_memory, :strict_vector_seam, IndeterminateSeam)

    assert {:error, :indeterminate} =
             MemoryStore.embed_confirmed(
               "aw_embed_indet",
               "async_writer",
               "indet",
               "indeterminate content",
               "thought",
               nil
             )
  end

  test "embed_confirmed maps a seam raise to indeterminate (never success)" do
    Application.put_env(:arbor_memory, :strict_vector_seam, ExceptionSeam)

    assert {:error, :indeterminate} =
             MemoryStore.embed_confirmed(
               "aw_embed_exc",
               "async_writer",
               "exc",
               "exception content",
               "thought",
               nil
             )
  end

  test "embed_confirmed maps a seam exit to indeterminate (never success)" do
    Application.put_env(:arbor_memory, :strict_vector_seam, ExitSeam)

    assert {:error, :indeterminate} =
             MemoryStore.embed_confirmed(
               "aw_embed_exit",
               "async_writer",
               "exit",
               "exit content",
               "thought",
               nil
             )
  end

  defp restore_memory_env(key, nil), do: Application.delete_env(:arbor_memory, key)
  defp restore_memory_env(key, value), do: Application.put_env(:arbor_memory, key, value)

  defp restore_ai_env(key, nil), do: Application.delete_env(:arbor_ai, key)
  defp restore_ai_env(key, value), do: Application.put_env(:arbor_ai, key, value)
end

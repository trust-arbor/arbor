defmodule Arbor.Memory.AsyncWriterTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory.AsyncWriter
  alias Arbor.Memory.AsyncWriter.Operation
  alias Arbor.Memory.AsyncWriter.Supervisor, as: WriterSupervisor
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B0"

  test "rejects invalid agent_id before a worker exists" do
    before = writer_children()

    assert {:error, {:memory_store, :invalid_request, :invalid_agent_id}} =
             MemoryStore.persist_async("async_writer", "k", %{"v" => 1})

    assert {:error, {:memory_store, :invalid_request, :invalid_agent_id}} =
             MemoryStore.persist_async("async_writer", "k", %{"v" => 1}, agent_id: "  padded  ")

    assert {:error, {:memory_store, :invalid_request, :invalid_agent_id}} =
             MemoryStore.persist_async("async_writer", "k", %{"v" => 1}, agent_id: "")

    assert {:error, {:memory_store, :invalid_request, :invalid_agent_id}} =
             MemoryStore.embed_async("async_writer", "k", "effectful content")

    assert {:error, {:memory_store, :invalid_request, :invalid_agent_id}} =
             MemoryStore.embed_async("async_writer", "k", "effectful content", agent_id: nil)

    assert writer_children() == before
  end

  test "preserves no-op for non-effectful embed content without agent_id" do
    assert :ok = MemoryStore.embed_async("async_writer", "k", "")
    assert :ok = MemoryStore.embed_async("async_writer", "k", nil)
  end

  test "rejects malformed operation data before start_child" do
    before = writer_children()

    assert {:error, {:memory_store, :async_writer, :invalid_operation}} =
             AsyncWriter.start({:persist, %{}})

    assert {:error, {:memory_store, :async_writer, :invalid_operation}} =
             AsyncWriter.start({:embed, %{agent_id: "a", namespace: "n", key: "k"}})

    assert {:error, {:memory_store, :async_writer, :invalid_operation}} =
             AsyncWriter.start(:not_an_operation)

    assert writer_children() == before
    assert :error = Operation.validate_agent_id(nil)
  end

  test "supervisor start fails on invalid max_children" do
    original = Application.get_env(:arbor_memory, :async_writer_max_children)
    Application.put_env(:arbor_memory, :async_writer_max_children, 0)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:arbor_memory, :async_writer_max_children)
        value -> Application.put_env(:arbor_memory, :async_writer_max_children, value)
      end
    end)

    assert {:error, :invalid_config} =
             WriterSupervisor.start_link(name: :"aw_bad_max_#{System.unique_integer([:positive])}")
  end

  test "rejects invalid persist_async options without a worker" do
    before = writer_children()

    assert {:error, {:memory_store, :invalid_request, :invalid_options}} =
             MemoryStore.persist_async("async_writer", "k", %{}, [:taint])

    assert {:error, {:memory_store, :invalid_request, :invalid_arguments}} =
             MemoryStore.persist_async(:ns, "k", %{})

    assert writer_children() == before
  end

  test "missing supervisor returns unavailable with no root" do
    agent_id = "aw_missing_#{System.unique_integer([:positive])}"
    id = WriterSupervisor.name()

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, id)

    try do
      assert {:error, {:memory_store, :async_writer, :unavailable}} =
               MemoryStore.persist_async("async_writer", "missing", %{"v" => 1}, agent_id: agent_id)

      assert {:error, {:memory_store, :async_writer, :unavailable}} =
               MemoryStore.embed_async("async_writer", "missing", "content",
                 agent_id: agent_id,
                 type: :thought
               )

      assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    after
      _ = Supervisor.restart_child(Arbor.Memory.Supervisor, id)
    end
  end

  test "destroyed gate rejects without a worker or root" do
    agent_id = "aw_destroyed_#{System.unique_integer([:positive])}"
    assert {:ok, fence} = MutationAdmission.drain(agent_id)
    assert :ok = MutationAdmission.mark_destroyed(fence)
    before = writer_children()

    assert {:error, {:memory_store, :async_writer, :destroyed}} =
             MemoryStore.persist_async("async_writer", "gone", %{"v" => 1}, agent_id: agent_id)

    assert {:error, {:memory_store, :async_writer, :destroyed}} =
             MemoryStore.embed_async("async_writer", "gone", "effectful content",
               agent_id: agent_id,
               type: :thought
             )

    assert writer_children() == before
    assert {:ok, %{gate: :destroyed, active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  defp writer_children do
    case Process.whereis(WriterSupervisor.name()) do
      nil -> []
      pid -> DynamicSupervisor.which_children(pid)
    end
  end
end

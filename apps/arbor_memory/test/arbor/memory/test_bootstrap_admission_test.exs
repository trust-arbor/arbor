defmodule Arbor.Memory.TestBootstrapAdmissionTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory.AsyncWriter.Supervisor, as: WriterSupervisor
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.TestBootstrap
  alias Arbor.Memory.TestBootstrap.AdmissionBackend

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B0"

  test "start! is idempotent and admission-ready" do
    assert :ok = TestBootstrap.start!(authority: false)
    assert :ok = TestBootstrap.start!(authority: false)

    assert {:ok, %{durability: :node_restart}} = MutationAdmission.readiness()
    assert is_pid(Process.whereis(WriterSupervisor.name()))
    assert is_pid(Process.whereis(AdmissionBackend.name()))
  end

  test "explicit admission opt-out does not start writer or admission" do
    writer_id = WriterSupervisor.name()
    admission_id = MutationAdmission

    :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, writer_id)
    :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, admission_id)

    try do
      assert :ok = TestBootstrap.start!(authority: false, admission: false)
      assert Process.whereis(writer_id) == nil
      assert Process.whereis(admission_id) == nil

      assert {:error, {:memory_store, :async_writer, :unavailable}} =
               MemoryStore.persist_async("async_writer", "opt-out", %{"v" => 1},
                 agent_id: "aw_opt_out"
               )
    after
      _ = Supervisor.restart_child(Arbor.Memory.Supervisor, admission_id)
      _ = Supervisor.restart_child(Arbor.Memory.Supervisor, writer_id)
      _ = TestBootstrap.start!(authority: false)
    end
  end

  test "admission backend refuses without explicit bootstrap topology opt" do
    assert {:error, :disabled} =
             AdmissionBackend.start_link(
               agent_name: :"aw_bootstrap_refuse_#{System.unique_integer([:positive])}"
             )
  end

  test "admission backend refuses when production children would start" do
    original = Application.get_env(:arbor_memory, :start_children)
    Application.put_env(:arbor_memory, :start_children, true)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:arbor_memory, :start_children)
        value -> Application.put_env(:arbor_memory, :start_children, value)
      end
    end)

    assert {:error, :disabled} =
             AdmissionBackend.start_link(
               agent_name: :"aw_bootstrap_prod_#{System.unique_integer([:positive])}",
               allow_test_bootstrap: true
             )
  end
end

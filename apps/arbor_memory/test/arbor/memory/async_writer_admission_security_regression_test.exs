defmodule Arbor.Memory.AsyncWriterAdmissionSecurityRegressionTest do
  @moduledoc """
  Public-API security regression for admission-owned async MemoryStore writes.

  Self-contained: starts a default-named MutationAdmission stack when the
  parent checkout has none, so drain succeeds on HEAD~1. After drain,
  effectful persist_async/4 and embed_async/4 must reject with no durable
  effect, provider call, vector operation, worker, or active root.

  On the immediate parent, Task.start still admits the write after drain, so
  the rejection assertions fail behaviorally.
  """

  use ExUnit.Case, async: false

  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B0"
  @moduletag security_regression: true

  @store_name :arbor_memory_durable
  @writer_supervisor_name Module.concat([Arbor, Memory, AsyncWriter, Supervisor])
  @admission_registry Arbor.Memory.MutationAdmission.Registry
  @guardian_supervisor Arbor.Memory.MutationAdmission.GuardianSupervisor
  @fake_name :aw_sec_ma_fake

  defmodule CountingSeam do
    @moduledoc false

    def fetch(_agent_id, _namespace, _key, _opts) do
      bump(:vector)
      {:error, :not_found}
    end

    def encode_operation(_closed) do
      bump(:vector)
      {:error, :unavailable}
    end

    def execute(_agent_id, _operation, _opts) do
      bump(:vector)
      {:error, :unavailable}
    end

    def reconcile(_agent_id, _operation, _opts) do
      bump(:vector)
      {:error, :unavailable}
    end

    def search(_agent_id, _vector, _opts), do: {:ok, []}
    def list(_agent_id, _opts), do: {:ok, []}
    def destroy(_agent_id, _opts), do: :ok

    defp bump(key) do
      case Process.whereis(:aw_sec_counters) do
        nil -> :ok
        pid -> Agent.update(pid, fn counts -> Map.update!(counts, key, &(&1 + 1)) end)
      end
    end
  end

  setup do
    {:ok, counters} = Agent.start_link(fn -> %{provider: 0, vector: 0} end, name: :aw_sec_counters)

    original_seam = Application.get_env(:arbor_memory, :strict_vector_seam)
    Application.put_env(:arbor_memory, :strict_vector_seam, CountingSeam)

    unless Process.whereis(@store_name) do
      start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})
    end

    ensure_default_admission!()
    tracer = start_embed_tracer()

    on_exit(fn ->
      stop_embed_tracer(tracer)
      restore_seam(original_seam)

      if Process.whereis(:aw_sec_counters) do
        Agent.stop(counters)
      end
    end)

    {:ok, counters: counters}
  end

  test "effectful persist_async and embed_async reject after drain with no effect", %{
    counters: counters
  } do
    agent_id = "aw_sec_#{System.unique_integer([:positive])}"
    persist_key = "sec-persist-#{System.unique_integer([:positive])}"
    embed_key = "sec-embed-#{System.unique_integer([:positive])}"

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)

    assert {:error, {:memory_store, :async_writer, :draining}} =
             MemoryStore.persist_async("async_writer", persist_key, %{"secret" => "no-write"},
               agent_id: agent_id
             )

    assert {:error, {:memory_store, :async_writer, :draining}} =
             MemoryStore.embed_async("async_writer", embed_key, "secret-embed-content",
               agent_id: agent_id,
               type: :thought
             )

    Process.sleep(50)

    assert {:error, :not_found} =
             BufferedStore.get("async_writer:#{persist_key}", name: @store_name)

    counts = Agent.get(counters, & &1)
    assert counts.provider == 0
    assert counts.vector == 0
    assert writer_children() == []

    assert {:ok, %{gate: :draining, active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  defp ensure_default_admission! do
    case MutationAdmission.readiness() do
      {:ok, %{durability: :node_restart}} ->
        :ok

      _ ->
        start_parent_admission_stack!()
    end
  end

  defp start_parent_admission_stack! do
    unless Process.whereis(@fake_name) do
      {:ok, _} = Fake.start_link(agent_name: @fake_name)
    end

    unless Process.whereis(@admission_registry) do
      start_supervised!({Registry, keys: :unique, name: @admission_registry})
    end

    unless Process.whereis(@guardian_supervisor) do
      start_supervised!({@guardian_supervisor, []})
    end

    unless Process.whereis(MutationAdmission) do
      start_supervised!(
        {MutationAdmission,
         [
           target: %{
             namespace: :memory_mutation_admission,
             backend: Fake,
             opts: [agent_name: @fake_name]
           }
         ]}
      )
    end

    assert {:ok, %{durability: :node_restart}} = MutationAdmission.readiness()
  end

  defp writer_children do
    case Process.whereis(@writer_supervisor_name) do
      nil ->
        []

      pid when is_pid(pid) ->
        DynamicSupervisor.which_children(pid)
    end
  end

  defp restore_seam(nil), do: Application.delete_env(:arbor_memory, :strict_vector_seam)
  defp restore_seam(seam), do: Application.put_env(:arbor_memory, :strict_vector_seam, seam)

  defp start_embed_tracer do
    tracer = spawn(fn -> embed_tracer_loop() end)
    :erlang.trace_pattern({Arbor.AI, :embed, 1}, true, [:local])
    :erlang.trace_pattern({Arbor.AI, :embed, 2}, true, [:local])
    :erlang.trace(:new, true, [:call, {:tracer, tracer}])
    tracer
  end

  defp stop_embed_tracer(tracer) when is_pid(tracer) do
    :erlang.trace(:new, false, [:call])
    :erlang.trace_pattern({Arbor.AI, :embed, 1}, false, [:local])
    :erlang.trace_pattern({Arbor.AI, :embed, 2}, false, [:local])
    send(tracer, :stop)
    :ok
  end

  defp embed_tracer_loop do
    receive do
      {:trace, _pid, :call, {Arbor.AI, :embed, _args}} ->
        case Process.whereis(:aw_sec_counters) do
          nil -> :ok
          pid -> Agent.update(pid, fn counts -> Map.update!(counts, :provider, &(&1 + 1)) end)
        end

        embed_tracer_loop()

      :stop ->
        :ok

      _other ->
        embed_tracer_loop()
    end
  end
end

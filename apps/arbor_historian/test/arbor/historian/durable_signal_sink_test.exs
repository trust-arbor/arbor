defmodule Arbor.Historian.DurableSignalSinkTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :fast

  alias Arbor.Persistence
  alias Arbor.Persistence.EventLog.ETS

  setup do
    originals = %{
      hot: Application.get_env(:arbor_historian, :hot_event_log_target, :unset),
      durable: Application.get_env(:arbor_historian, :durable_event_log_target, :unset),
      starter: Application.get_env(:arbor_historian, :durable_task_starter, :unset)
    }

    Arbor.Signals.Config.Testing.isolate_namespace()
    Application.delete_env(:arbor_historian, :durable_task_starter)

    on_exit(fn ->
      restore(:arbor_historian, :hot_event_log_target, originals.hot)
      restore(:arbor_historian, :durable_event_log_target, originals.durable)
      restore(:arbor_historian, :durable_task_starter, originals.starter)
    end)

    :ok
  end

  test "facade exports persist_durable_event/4 and the Signals durable-sink behaviour" do
    assert {:module, Arbor.Historian} = Code.ensure_loaded(Arbor.Historian)
    assert function_exported?(Arbor.Historian, :persist_durable_event, 4)

    behaviours =
      Arbor.Historian.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Arbor.Signals.Contracts.DurableSink in behaviours
  end

  test "hot append is visible before durable_emit returns and durable runs asynchronously" do
    ctx = start_isolated_targets()
    ensure_signals()
    Arbor.Signals.Config.Testing.put(:durable_sink_module, Arbor.Historian)

    stream_id = "k1e_async_#{System.unique_integer([:positive])}"
    type = :"async_probe_#{System.unique_integer([:positive])}"
    test_pid = self()

    Application.put_env(:arbor_historian, :durable_task_starter, fn fun ->
      Task.start(fn ->
        fun.()
        send(test_pid, {:durable_appended, stream_id, self()})
      end)
    end)

    assert :ok =
             Arbor.Signals.durable_emit(:activity, type, %{probe: true}, stream_id: stream_id)

    event = read_event!(ctx.hot, stream_id, type)
    assert event.data["probe"] == true
    refute Map.has_key?(event.data, "permanent")
    refute Map.has_key?(event.data, :permanent)

    assert_receive {:durable_appended, ^stream_id, worker}, 1_000
    assert worker != self()
    assert read_event!(ctx.durable, stream_id, type)
  end

  test "security regression: durable_emit preserves lineage and caller metadata at EventLog boundary" do
    ctx = start_isolated_targets()
    ensure_signals()
    Arbor.Signals.Config.Testing.put(:durable_sink_module, Arbor.Historian)

    suffix = System.unique_integer([:positive])
    stream_id = "audit_lineage_#{suffix}"
    type = :"lineage_probe_#{suffix}"
    corr = "corr_lineage_#{suffix}"
    cause = "cause_lineage_#{suffix}"
    agent = "agent_lineage_#{suffix}"

    assert :ok =
             Arbor.Signals.durable_emit(
               :activity,
               type,
               %{probe: true},
               stream_id: stream_id,
               correlation_id: corr,
               cause_id: cause,
               agent_id: agent,
               metadata: %{
                 "source_node" => "spoofed_string_node",
                 audit_reason: "lineage_regression",
                 source_node: :spoofed_atom_node
               }
             )

    event = read_event!(ctx.hot, stream_id, type)

    assert event.correlation_id == corr
    assert event.causation_id == cause
    assert event.agent_id == agent
    assert event.metadata["audit_reason"] == "lineage_regression"
    assert event.type == to_string(type)
    assert event.data["timestamp"]
    refute Map.has_key?(event.data, "permanent")

    system_node = to_string(node())
    assert event.metadata["source_node"] == system_node

    refute event.metadata["source_node"] in [
             "spoofed_atom_node",
             ":spoofed_atom_node",
             "spoofed_string_node"
           ]

    refute Map.has_key?(event.metadata, :source_node)
  end

  test "security regression: absent lineage opts stay nil without empty sentinels" do
    ctx = start_isolated_targets()
    ensure_signals()
    Arbor.Signals.Config.Testing.put(:durable_sink_module, Arbor.Historian)

    suffix = System.unique_integer([:positive])
    stream_id = "audit_lineage_absent_#{suffix}"
    type = :"lineage_absent_#{suffix}"

    assert :ok =
             Arbor.Signals.durable_emit(:activity, type, %{probe: true}, stream_id: stream_id)

    event = read_event!(ctx.hot, stream_id, type)

    assert is_nil(event.correlation_id)
    assert is_nil(event.causation_id)
    assert is_nil(event.agent_id)
    assert is_map(event.metadata)
    assert Map.has_key?(event.metadata, "source_node")
    refute Map.get(event.metadata, "correlation_id") in ["", "nil"]
  end

  test "writes isolated Config targets rather than leftover hardcoded names" do
    ctx = start_isolated_targets()
    ensure_signals()
    Arbor.Signals.Config.Testing.put(:durable_sink_module, Arbor.Historian)

    stream_id = "k1e_isolated_#{System.unique_integer([:positive])}"
    type = :"isolated_#{System.unique_integer([:positive])}"

    assert :ok =
             Arbor.Historian.persist_durable_event(stream_id, type, %{isolated: true}, [])

    assert read_event!(ctx.hot, stream_id, type)
    refute ctx.hot == Arbor.Historian.EventLog.ETS
  end

  test "invalid or unavailable targets and append failures log bounded gaps and stay :ok" do
    ensure_signals()
    Arbor.Signals.Config.Testing.put(:durable_sink_module, Arbor.Historian)

    stream_id = "k1e_gap_#{System.unique_integer([:positive])}"
    payload = %{secret: "payload"}

    Application.put_env(:arbor_historian, :hot_event_log_target, %{invalid: true})
    Application.put_env(:arbor_historian, :durable_event_log_target, %{invalid: true})

    log =
      capture_log(fn ->
        assert :ok = Arbor.Signals.durable_emit(:activity, :gap, payload, stream_id: stream_id)
      end)

    assert log =~ stream_id
    assert log =~ "hot_target_invalid"
    assert log =~ "durable_target_invalid"
    refute log =~ "secret"
    refute log =~ "payload"

    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    missing_hot = :"k1e_missing_hot_#{System.unique_integer([:positive])}"

    Application.put_env(:arbor_historian, :hot_event_log_target, %{
      name: missing_hot,
      backend: ETS,
      opts: []
    })

    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: :k1e_missing_durable,
      backend: :k1e_missing_backend_module,
      opts: []
    })

    log =
      capture_log(fn ->
        assert :ok = Arbor.Historian.persist_durable_event(stream_id, :gap, payload, [])
      end)

    assert log =~ "hot_unavailable"
    assert log =~ "durable_backend_unavailable"
    refute log =~ "secret"

    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: :k1e_absent_repo_log,
      backend: ETS,
      opts: [repo: :k1e_absent_configured_repo]
    })

    log =
      capture_log(fn ->
        assert :ok = Arbor.Historian.persist_durable_event(stream_id, :gap, payload, [])
      end)

    assert log =~ "durable_repo_unavailable"
    refute Process.whereis(:k1e_absent_configured_repo)

    ctx = start_isolated_targets()

    Application.put_env(:arbor_historian, :hot_event_log_target, %{
      name: ctx.hot,
      backend: __MODULE__.ErrorBackend,
      opts: []
    })

    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: ctx.durable,
      backend: __MODULE__.ErrorBackend,
      opts: []
    })

    Application.put_env(:arbor_historian, :durable_task_starter, fn fun ->
      fun.()
      {:ok, self()}
    end)

    log =
      capture_log(fn ->
        assert :ok = Arbor.Historian.persist_durable_event(stream_id, :gap, payload, [])
      end)

    assert log =~ "hot_append_failed"
    assert log =~ "durable_append_failed"
    refute log =~ "secret"

    Application.put_env(:arbor_historian, :hot_event_log_target, %{
      name: ctx.hot,
      backend: ETS,
      opts: []
    })

    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: ctx.durable,
      backend: ETS,
      opts: []
    })

    starters = [
      fn _fun -> {:error, :too_many_children} end,
      fn _fun -> :not_a_task end,
      fn _fun -> {:ok, :not_a_pid} end,
      fn _fun -> raise "starter boom" end,
      fn _fun -> throw(:starter_throw) end,
      fn _fun -> exit(:starter_exit) end
    ]

    Enum.each(starters, fn starter ->
      Application.put_env(:arbor_historian, :durable_task_starter, starter)

      log =
        capture_log(fn ->
          assert :ok = Arbor.Historian.persist_durable_event(stream_id, :gap, payload, [])
        end)

      assert log =~ "durable_spawn_failed"
      refute log =~ "too_many_children"
      refute log =~ "starter boom"
      refute log =~ "starter_throw"
      refute log =~ "starter_exit"
    end)
  end

  test "security regression: long stream_id is bounded and tail is absent from logs" do
    Application.put_env(:arbor_historian, :hot_event_log_target, %{invalid: true})
    Application.put_env(:arbor_historian, :durable_event_log_target, %{invalid: true})

    tail = "TAIL_MUST_NOT_APPEAR_k1e"
    stream_id = String.duplicate("s", 80) <> tail

    log =
      capture_log(fn ->
        assert :ok = Arbor.Historian.persist_durable_event(stream_id, :gap, %{}, [])
      end)

    assert log =~ "hot_target_invalid"
    assert log =~ String.duplicate("s", 64)
    assert log =~ "..."
    refute log =~ tail
    refute log =~ stream_id
  end

  test "security regression: invalid UTF-8 stream_id cannot escape logs or raise" do
    Application.put_env(:arbor_historian, :hot_event_log_target, %{invalid: true})
    Application.put_env(:arbor_historian, :durable_event_log_target, %{invalid: true})

    tail = "TAIL_INVALID_UTF8_k1e"
    stream_id = <<"head", 0xFF, 0xFE>> <> String.duplicate("x", 80) <> tail

    log =
      capture_log(fn ->
        assert :ok = Arbor.Historian.persist_durable_event(stream_id, :gap, %{}, [])
      end)

    assert log =~ "stream=head??"
    assert log =~ "hot_target_invalid"
    assert log =~ "durable_target_invalid"
    refute log =~ tail
    refute log =~ <<0xFF, 0xFE>>
    refute log =~ stream_id
  end

  defp start_isolated_targets do
    suffix = System.unique_integer([:positive])
    # credo:disable-for-lines:2 Credo.Check.Security.UnsafeAtomConversion
    hot = :"k1e_hot_#{suffix}"
    durable = :"k1e_durable_#{suffix}"

    start_event_log!(hot)
    start_event_log!(durable)

    Application.put_env(:arbor_historian, :hot_event_log_target, %{
      name: hot,
      backend: ETS,
      opts: []
    })

    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: durable,
      backend: ETS,
      opts: []
    })

    %{hot: hot, durable: durable}
  end

  defp start_event_log!(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        {:ok, pid} = ETS.start_link(name: name)

        on_exit(fn ->
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid)
            catch
              :exit, _ -> :ok
            end
          end
        end)
    end
  end

  defp ensure_signals do
    Application.ensure_all_started(:arbor_kernel_runtime)

    Enum.each([Arbor.Signals.Store, Arbor.Signals.Bus], fn mod ->
      unless Process.whereis(mod) do
        {:ok, _} = mod.start_link([])
      end
    end)
  end

  defp read_event!(name, stream_id, type) do
    assert {:ok, events} = Persistence.read_stream(name, ETS, stream_id)
    type_str = to_string(type)

    Enum.find(events, &(&1.type == type_str)) ||
      flunk("expected event type #{inspect(type_str)} in #{inspect(stream_id)}")
  end

  defp restore(app, key, :unset), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defmodule ErrorBackend do
    def append(_stream_id, _events, _opts), do: {:error, :boom}
  end
end

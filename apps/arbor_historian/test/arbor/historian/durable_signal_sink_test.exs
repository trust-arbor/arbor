defmodule Arbor.Historian.DurableSignalSinkTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :fast

  alias Arbor.Persistence
  alias Arbor.Persistence.EventLog.ETS

  alias Arbor.Historian.DurableSignalSinkTest.{
    ErrorBackend,
    MalformedBackend,
    MalformedSuccessBackend,
    ProjectionErrorBackend,
    RaisingBackend
  }

  setup do
    Arbor.Signals.Config.Testing.isolate_namespace()

    originals = %{
      hot: Application.fetch_env(:arbor_historian, :hot_event_log_target),
      durable: Application.fetch_env(:arbor_historian, :durable_event_log_target),
      reply_mode: Application.fetch_env(:arbor_historian, :durable_reply_mode)
    }

    on_exit(fn ->
      restore(:hot_event_log_target, originals.hot)
      restore(:durable_event_log_target, originals.durable)
      restore(:durable_reply_mode, originals.reply_mode)
    end)

    :ok
  end

  test "durable acknowledgement precedes projection and projection uses exact assigned positions" do
    ctx = start_isolated_targets()

    configure_target(:durable_event_log_target, ctx.durable, ETS)
    configure_target(:hot_event_log_target, ctx.hot, ETS)

    stream_id = unique_stream("durable_first")
    :ok = :sys.suspend(ctx.hot)

    task =
      Task.async(fn ->
        Arbor.Historian.persist_durable_event(
          stream_id,
          :ordered,
          %{probe: true},
          correlation_id: "corr",
          cause_id: "cause"
        )
      end)

    task_ref = task.ref

    durable_event =
      try do
        assert {:ok, [event]} = await_durable_event(ctx.durable, stream_id)
        refute_receive {^task_ref, _result}
        assert event.event_number == 1
        assert event.global_position == 1
        event
      after
        :ok = :sys.resume(ctx.hot)
      end

    assert :ok = Task.await(task)
    assert {:ok, [^durable_event]} = Persistence.read_stream(ctx.durable, ETS, stream_id)
    assert {:ok, [projected_event]} = Persistence.read_stream(ctx.hot, ETS, stream_id)
    assert projected_event === durable_event
  end

  test "durable failure is persist_failed and cannot create a hot phantom" do
    ctx = start_isolated_targets()
    assert {:module, ErrorBackend} = Code.ensure_loaded(ErrorBackend)
    configure_target(:durable_event_log_target, ctx.durable, ErrorBackend)
    configure_target(:hot_event_log_target, ctx.hot, ETS)
    stream_id = unique_stream("no_phantom")

    assert {:error, :persist_failed} =
             Arbor.Historian.persist_durable_event(stream_id, :failed, %{secret: "payload"}, [])

    assert {:ok, []} = Persistence.read_stream(ctx.hot, ETS, stream_id)
  end

  test "Signals durable_emit remains best-effort when Historian rejects the durable write" do
    ctx = start_isolated_targets()
    configure_target(:durable_event_log_target, ctx.durable, ErrorBackend)
    configure_target(:hot_event_log_target, ctx.hot, ETS)
    Arbor.Signals.Config.Testing.put(:durable_sink_module, Arbor.Historian)
    stream_id = unique_stream("signals_best_effort")

    capture_log(fn ->
      assert {:error, :persist_failed} =
               Arbor.Historian.persist_durable_event(stream_id, :direct, %{value: 1}, [])

      assert :ok =
               Arbor.Signals.durable_emit(:activity, :via_bus, %{value: 2}, stream_id: stream_id)
    end)

    assert {:ok, []} = Persistence.read_stream(ctx.hot, ETS, stream_id)
  end

  test "malformed successful durable replies cannot reach the hot projection" do
    ctx = start_isolated_targets()
    assert {:module, MalformedSuccessBackend} = Code.ensure_loaded(MalformedSuccessBackend)
    configure_target(:durable_event_log_target, ctx.durable, MalformedSuccessBackend)
    configure_target(:hot_event_log_target, ctx.hot, ETS)
    stream_id = unique_stream("malformed_success")

    log =
      capture_log(fn ->
        for mode <- [:wrong_stream, :wrong_event, :wrong_event_id, :bad_fingerprint, :extra_event] do
          Application.put_env(:arbor_historian, :durable_reply_mode, mode)

          assert {:error, :persist_failed} =
                   Arbor.Historian.persist_durable_event(stream_id, :submitted, %{value: 1}, [])
        end
      end)

    assert length(Regex.scan(~r/reason=durable_append_malformed/, log)) == 5
    assert {:ok, []} = Persistence.read_stream(ctx.hot, ETS, stream_id)
  end

  test "invalid, unavailable, raised, malformed, and failed durable writes normalize" do
    ctx = start_isolated_targets()
    Enum.each([RaisingBackend, MalformedBackend, ErrorBackend], &Code.ensure_loaded!/1)
    configure_target(:hot_event_log_target, ctx.hot, ETS)
    stream_id = unique_stream("durable_failures")

    failures = [
      %{invalid: true},
      %{name: ctx.durable, backend: :missing_durable_backend, opts: []},
      %{name: ctx.durable, backend: RaisingBackend, opts: []},
      %{name: ctx.durable, backend: MalformedBackend, opts: []},
      %{name: ctx.durable, backend: ErrorBackend, opts: []}
    ]

    Enum.each(failures, fn target ->
      Application.put_env(:arbor_historian, :durable_event_log_target, target)

      assert {:error, :persist_failed} =
               Arbor.Historian.persist_durable_event(stream_id, :failed, %{}, [])
    end)

    assert {:ok, []} = Persistence.read_stream(ctx.hot, ETS, stream_id)
  end

  test "projection failure cannot negate durable success" do
    ctx = start_isolated_targets()
    configure_target(:durable_event_log_target, ctx.durable, ETS)
    configure_target(:hot_event_log_target, ctx.hot, ProjectionErrorBackend)
    stream_id = unique_stream("projection_gap")

    log =
      capture_log(fn ->
        assert :ok =
                 Arbor.Historian.persist_durable_event(
                   stream_id,
                   :committed,
                   %{secret: "payload"},
                   []
                 )
      end)

    assert log =~ "hot_projection_failed"
    refute log =~ "secret"
    refute log =~ "payload"
    assert {:ok, [_event]} = Persistence.read_stream(ctx.durable, ETS, stream_id)
    assert {:ok, []} = Persistence.read_stream(ctx.hot, ETS, stream_id)
  end

  test "absent, invalid, and unsupported hot projections remain successful gaps" do
    ctx = start_isolated_targets()
    configure_target(:durable_event_log_target, ctx.durable, ETS)
    stream_id = unique_stream("hot_gaps")

    hot_targets = [
      %{invalid: true},
      %{name: :absent_hot_projection, backend: ETS, opts: []},
      %{name: ctx.hot, backend: ErrorBackend, opts: []}
    ]

    Enum.each(hot_targets, fn target ->
      Application.put_env(:arbor_historian, :hot_event_log_target, target)
      assert :ok = Arbor.Historian.persist_durable_event(stream_id, :committed, %{}, [])
    end)

    assert {:ok, events} = Persistence.read_stream(ctx.durable, ETS, stream_id)
    assert length(events) == 3
  end

  test "lineage and system-owned source_node survive the durable-first boundary" do
    ctx = start_isolated_targets()
    configure_target(:durable_event_log_target, ctx.durable, ETS)
    configure_target(:hot_event_log_target, ctx.hot, ETS)
    stream_id = unique_stream("lineage")

    assert :ok =
             Arbor.Historian.persist_durable_event(
               stream_id,
               :lineage,
               %{probe: true},
               correlation_id: "corr",
               cause_id: "cause",
               agent_id: "agent",
               metadata: %{
                 "source_node" => "spoofed-string",
                 source_node: :spoofed_atom,
                 audit_reason: "regression"
               }
             )

    assert {:ok, [durable_event]} = Persistence.read_stream(ctx.durable, ETS, stream_id)
    assert {:ok, [hot_event]} = Persistence.read_stream(ctx.hot, ETS, stream_id)
    assert durable_event === hot_event
    assert durable_event.correlation_id == "corr"
    assert durable_event.causation_id == "cause"
    assert durable_event.agent_id == "agent"
    assert durable_event.metadata["audit_reason"] == "regression"
    assert durable_event.metadata["source_node"] == to_string(node())
    refute Map.has_key?(durable_event.metadata, :source_node)
  end

  test "invalid UTF-8 and long stream ids are logged safely within the 64-byte bound" do
    Application.put_env(:arbor_historian, :durable_event_log_target, %{invalid: true})
    tail = "TAIL_MUST_NOT_APPEAR"
    stream_id = <<"head", 0xFF, 0xFE>> <> String.duplicate("x", 80) <> tail

    log =
      capture_log(fn ->
        assert {:error, :persist_failed} =
                 Arbor.Historian.persist_durable_event(stream_id, :gap, %{}, [])
      end)

    assert log =~ "stream=head??"
    assert log =~ "..."
    refute log =~ tail
    refute log =~ <<0xFF, 0xFE>>
    refute log =~ stream_id
  end

  defmodule ErrorBackend do
    def append(_stream_id, _events, _opts), do: {:error, :boom}
  end

  defmodule RaisingBackend do
    def append(_stream_id, _events, _opts), do: raise("secret backend exception")
  end

  defmodule MalformedBackend do
    def append(_stream_id, _events, _opts), do: {:ok, []}
  end

  defmodule MalformedSuccessBackend do
    alias Arbor.Persistence.Event

    def append(stream_id, [%Event{} = submitted], _opts) do
      %Event{} = committed = position(submitted, stream_id, 1, 1)

      case Application.fetch_env!(:arbor_historian, :durable_reply_mode) do
        :wrong_stream ->
          wrong = %Event{committed | stream_id: "another-stream"}
          {:ok, [fingerprint(wrong, wrong.stream_id)]}

        :wrong_event ->
          wrong = %Event{committed | type: "different-type"}
          {:ok, [fingerprint(wrong, stream_id)]}

        :wrong_event_id ->
          wrong = %Event{committed | id: "evt_wrong_identity"}
          {:ok, [fingerprint(wrong, stream_id)]}

        :bad_fingerprint ->
          {:ok, [%Event{committed | operation_fingerprint: "not-canonical"}]}

        :extra_event ->
          extra =
            %Event{committed | id: "evt_extra", event_number: 2, global_position: 2}
            |> fingerprint(stream_id)

          {:ok, [committed, extra]}
      end
    end

    defp position(%Event{} = event, stream_id, event_number, global_position) do
      %Event{event | event_number: event_number, global_position: global_position}
      |> fingerprint(stream_id)
    end

    defp fingerprint(%Event{} = event, stream_id) do
      %Event{
        event
        | operation_fingerprint: Arbor.Persistence.canonical_event_fingerprint(stream_id, event)
      }
    end
  end

  defmodule ProjectionErrorBackend do
    def project_committed_events(_events, _opts), do: {:error, :boom}
  end

  defp start_isolated_targets do
    suffix = System.unique_integer([:positive])
    # credo:disable-for-lines:2 Credo.Check.Security.UnsafeAtomConversion
    hot = :"historian_hot_projection_#{suffix}"
    durable = :"historian_durable_log_#{suffix}"

    start_supervised!({ETS, name: durable}, id: durable)
    start_supervised!({ETS, name: hot, mode: :projection}, id: hot)

    configure_target(:durable_event_log_target, durable, ETS)
    configure_target(:hot_event_log_target, hot, ETS)

    %{hot: hot, durable: durable}
  end

  defp configure_target(key, name, backend) do
    Application.put_env(:arbor_historian, key, %{name: name, backend: backend, opts: []})
  end

  defp unique_stream(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp await_durable_event(name, stream_id, attempts \\ 50)

  defp await_durable_event(_name, _stream_id, 0), do: {:error, :timeout}

  defp await_durable_event(name, stream_id, attempts) do
    case Persistence.read_stream(name, ETS, stream_id) do
      {:ok, [_event]} = found ->
        found

      {:ok, []} ->
        Process.sleep(10)
        await_durable_event(name, stream_id, attempts - 1)
    end
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:arbor_historian, key, value)
  defp restore(key, :error), do: Application.delete_env(:arbor_historian, key)
end

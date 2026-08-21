defmodule Arbor.Historian.Adapters.SecurityEventLogTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Historian.Adapters.SecurityEventLog
  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS
  alias Arbor.Security.Events

  @stream_id "security:events"

  defmodule AuthoritySpyBackend do
    def read_stream(stream_id, opts) do
      record(opts, {:read, stream_id, opts})
      Agent.get(Keyword.fetch!(opts, :repo), &{:ok, &1.events})
    end

    defp record(opts, call) do
      Agent.update(Keyword.fetch!(opts, :repo), fn state ->
        send(state.owner, call)
        %{state | calls: [call | state.calls]}
      end)
    end
  end

  defmodule ErrorReadBackend do
    def read_stream(_stream_id, _opts), do: {:error, %{secret: "backend payload"}}
  end

  defmodule RaisingReadBackend do
    def read_stream(_stream_id, _opts), do: raise("backend payload")
  end

  defmodule ExitingReadBackend do
    def read_stream(_stream_id, _opts), do: exit(:backend_payload)
  end

  defmodule MalformedReadBackend do
    def read_stream(_stream_id, _opts), do: {:ok, %{secret: "backend payload"}}
  end

  setup do
    suffix = System.unique_integer([:positive])
    # credo:disable-for-lines:2 Credo.Check.Security.UnsafeAtomConversion
    durable = :"security_event_log_durable_#{suffix}"
    hot = :"security_event_log_hot_#{suffix}"

    start_supervised!({ETS, name: durable}, id: durable)
    start_supervised!({ETS, name: hot, mode: :projection}, id: hot)

    originals = %{
      durable: Application.fetch_env(:arbor_historian, :durable_event_log_target),
      hot: Application.fetch_env(:arbor_historian, :hot_event_log_target),
      adapter: Application.fetch_env(:arbor_security, :event_log_adapter)
    }

    configure_target(:durable_event_log_target, durable, ETS)
    configure_target(:hot_event_log_target, hot, ETS)

    Application.put_env(:arbor_security, :event_log_adapter, SecurityEventLog)

    on_exit(fn ->
      restore(:arbor_historian, :durable_event_log_target, originals.durable)
      restore(:arbor_historian, :hot_event_log_target, originals.hot)
      restore(:arbor_security, :event_log_adapter, originals.adapter)
    end)

    %{durable: durable, hot: hot, suffix: suffix}
  end

  test "security regression: direct adapter round trip uses durable authority", ctx do
    assert :ok =
             SecurityEventLog.persist_security_event(:authorization_granted, %{
               principal_id: "agent_001",
               resource_uri: "arbor://fs/read/docs"
             })

    assert {:ok, [event]} = SecurityEventLog.read_security_events([])
    assert event.stream_id == "security:events"
    assert event.type == "authorization_granted"
    assert event.data["principal_id"] == "agent_001"
    assert event.data["resource_uri"] == "arbor://fs/read/docs"
    assert is_binary(event.data["timestamp"])
    assert event.metadata["source_node"] in [node(), to_string(node())]

    assert {:ok, [durable_event]} = Persistence.read_stream(ctx.durable, ETS, @stream_id)
    assert durable_event == event
  end

  test "security regression: Events round trip reads durable authority", ctx do
    assert :ok =
             Events.record_orchestration_task_dispatched(
               "human_1",
               "task_123",
               "agent_1",
               task_preview: "write a patch",
               metadata: %{ticket: "A-1"},
               trace_id: "trace_abc"
             )

    assert :ok = stop_supervised(ctx.hot)

    assert {:ok, [event]} = Events.get_by_type(:orchestration_task_dispatched)
    assert event.stream_id == "security:events"
    assert event.data["actor_id"] == "human_1"
    assert event.data["task_id"] == "task_123"
    assert event.data["agent_id"] == "agent_1"
    assert event.data["task_preview"] == "write a patch"
    assert event.data["metadata"] == %{"ticket" => "A-1"}
    assert event.data["trace_id"] == "trace_abc"
    assert event.metadata["source_node"] == to_string(node())
  end

  test "security regression: durable acknowledgement survives hot projection loss", ctx do
    assert :ok =
             SecurityEventLog.persist_security_event(:authorization_denied, %{
               principal_id: "agent_survivor"
             })

    assert :ok = stop_supervised(ctx.hot)

    assert {:ok, [event]} = SecurityEventLog.read_security_events([])
    assert event.type == "authorization_denied"
    assert event.data["principal_id"] == "agent_survivor"
  end

  test "security regression: stale conflicting hot data never replaces durable history", ctx do
    assert {:ok, [durable_event]} =
             Persistence.append(
               ctx.durable,
               ETS,
               @stream_id,
               Event.new(@stream_id, "durable_truth", %{authority: "durable"})
             )

    stale_hot = positioned_event("stale_hot", %{authority: "hot"})

    assert {:ok, %{projected: 1, skipped: 0}} =
             Persistence.project_committed_events(ctx.hot, ETS, [stale_hot])

    assert {:ok, [read_event]} = SecurityEventLog.read_security_events([])
    assert read_event == durable_event
    assert read_event.type == "durable_truth"
    assert read_event.data["authority"] == "durable"
  end

  test "security regression: unavailable durable target cannot create hot-only audit success",
       ctx do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    writable_hot = :"security_event_log_writable_hot_#{ctx.suffix}"
    start_supervised!({ETS, name: writable_hot}, id: writable_hot)
    configure_target(:hot_event_log_target, writable_hot, ETS)
    assert :ok = stop_supervised(ctx.durable)

    assert {:error, :persist_failed} =
             SecurityEventLog.persist_security_event(:authorization_granted, %{
               principal_id: "agent_phantom"
             })

    assert {:ok, []} = Persistence.read_stream(writable_hot, ETS, @stream_id)
  end

  test "security regression: caller storage selectors cannot replace configured authority", ctx do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    repo = :"security_event_log_spy_#{ctx.suffix}"
    event = positioned_event("configured_authority", %{authority: "configured"})
    owner = self()

    {:ok, _repo_pid} =
      Agent.start_link(fn -> %{owner: owner, events: [event], calls: []} end, name: repo)

    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: ctx.durable,
      backend: AuthoritySpyBackend,
      opts: [repo: repo]
    })

    assert {:ok, [^event]} =
             SecurityEventLog.read_security_events(
               from: 2,
               limit: 1,
               direction: :backward,
               repo: :caller_repo,
               name: :caller_name,
               backend: ErrorReadBackend,
               opts: [repo: :caller_nested_repo],
               unknown: :caller_value
             )

    assert_receive {:read, @stream_id, read_opts}
    assert read_opts[:name] == ctx.durable
    assert read_opts[:repo] == repo

    assert Keyword.take(read_opts, [:from, :limit, :direction]) ==
             [from: 2, limit: 1, direction: :backward]

    refute Keyword.has_key?(read_opts, :backend)
    refute Keyword.has_key?(read_opts, :opts)
    refute Keyword.has_key?(read_opts, :unknown)
  end

  test "security regression: configured projection target is rejected for reads", ctx do
    configure_target(:durable_event_log_target, ctx.hot, ETS)

    assert {:error, :event_log_unavailable} = SecurityEventLog.read_security_events([])
  end

  test "security regression: durable read failures are bounded and never fall back to hot", ctx do
    stale_hot = positioned_event("stale_hot", %{secret: "hot payload"})

    assert {:ok, %{projected: 1, skipped: 0}} =
             Persistence.project_committed_events(ctx.hot, ETS, [stale_hot])

    targets = [
      %{invalid: true},
      %{name: ctx.durable, backend: ErrorReadBackend, opts: []},
      %{name: ctx.durable, backend: RaisingReadBackend, opts: []},
      %{name: ctx.durable, backend: ExitingReadBackend, opts: []},
      %{name: ctx.durable, backend: MalformedReadBackend, opts: []}
    ]

    Enum.each(targets, fn target ->
      Application.put_env(:arbor_historian, :durable_event_log_target, target)
      assert {:error, :event_log_unavailable} = SecurityEventLog.read_security_events([])
    end)
  end

  test "invalid inputs fail closed" do
    assert {:error, :invalid_event} = SecurityEventLog.persist_security_event("type", %{})
    assert {:error, :invalid_event} = SecurityEventLog.persist_security_event(:type, [])
    assert {:error, :event_log_unavailable} = SecurityEventLog.read_security_events(%{})
  end

  defp positioned_event(type, data) do
    event =
      @stream_id
      |> Event.new(type, data)
      |> Map.put(:event_number, 1)
      |> Map.put(:global_position, 1)

    %{event | operation_fingerprint: Persistence.canonical_event_fingerprint(@stream_id, event)}
  end

  defp configure_target(key, name, backend) do
    Application.put_env(:arbor_historian, key, %{name: name, backend: backend, opts: []})
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)
end

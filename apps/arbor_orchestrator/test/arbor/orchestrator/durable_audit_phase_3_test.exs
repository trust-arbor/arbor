defmodule Arbor.Orchestrator.DurableAuditPhase3Test do
  @moduledoc """
  Phase 3a of durable-execution-audit
  (`.arbor/roadmap/2-planned/durable-execution-audit.md`): the per-node outcome
  detail becomes a first-class, durably-persisted event (not just an on-disk
  `status.json` dump), and the event persist boundary is struct-safe via
  `JsonSafe` so enriched events can never crash the run at the durable
  `Jason.encode` / Ecto `:map` cast.
  """
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.{Engine, Event, Events, JsonSafe}
  alias Arbor.Persistence.EventLog.ETS

  @moduletag :fast

  defmodule Unencodable do
    defstruct [:ref, :note]
  end

  describe "JsonSafe.coerce/1" do
    test "flattens a non-Jason.Encoder struct to a plain map and makes it encodable" do
      term = %{"thing" => %Unencodable{ref: make_ref(), note: "hi"}}
      coerced = JsonSafe.coerce(term)

      assert is_map(coerced["thing"])
      assert coerced["thing"][:note] == "hi"
      # the embedded reference became an inspect string, not a crash
      assert is_binary(coerced["thing"][:ref])
      # the whole thing is now JSON-encodable (the footgun is closed)
      assert {:ok, _} = Jason.encode(coerced)
    end

    test "coerces pids, refs, functions, and tuples; passes datetimes through" do
      now = ~U[2026-06-15 12:00:00Z]

      coerced =
        JsonSafe.coerce(%{
          pid: self(),
          ref: make_ref(),
          fun: fn -> :x end,
          tuple: {:a, 1},
          when: now,
          nested: [%{deep: {:b, 2}}]
        })

      assert is_binary(coerced[:pid])
      assert is_binary(coerced[:ref])
      assert is_binary(coerced[:fun])
      assert coerced[:tuple] == [:a, 1]
      assert coerced[:when] == now
      assert coerced[:nested] == [%{deep: [:b, 2]}]
      assert {:ok, _} = Jason.encode(coerced)
    end

    test "non-string/atom map keys become inspect strings" do
      coerced = JsonSafe.coerce(%{{:a, :b} => 1})
      assert coerced["{:a, :b}"] == 1
    end
  end

  describe "Event.stage_completed/3 enrichment" do
    test "carries context_updates and notes when provided" do
      e =
        Event.stage_completed("n1", :success,
          duration_ms: 12,
          context_updates: %{"x" => 1},
          notes: "did a thing"
        )

      assert e.type == :stage_completed
      assert e.node_id == "n1"
      assert e.status == :success
      assert e.duration_ms == 12
      assert e.context_updates == %{"x" => 1}
      assert e.notes == "did a thing"
    end

    test "omits context_updates/notes when not provided (no nil keys)" do
      e = Event.stage_completed("n1", :success, duration_ms: 5)
      refute Map.has_key?(e, :context_updates)
      refute Map.has_key?(e, :notes)
    end
  end

  describe "durable persistence of an enriched, struct-bearing event" do
    setup do
      # Durable-first Historian writes: isolated authoritative ETS plus a separate
      # hot projection. read_run_events observes the durable authority.
      suffix = System.unique_integer([:positive])
      # credo:disable-for-lines:2 Credo.Check.Security.UnsafeAtomConversion
      durable = :"durable_audit_phase3_durable_#{suffix}"
      hot = :"durable_audit_phase3_hot_#{suffix}"

      start_supervised!({ETS, name: durable}, id: durable)
      start_supervised!({ETS, name: hot, mode: :projection}, id: hot)

      originals = %{
        event_log_name: Application.fetch_env(:arbor_orchestrator, :event_log_name),
        event_log_backend: Application.fetch_env(:arbor_orchestrator, :event_log_backend),
        durable: Application.fetch_env(:arbor_historian, :durable_event_log_target),
        hot: Application.fetch_env(:arbor_historian, :hot_event_log_target)
      }

      Application.put_env(:arbor_orchestrator, :event_log_name, durable)
      Application.put_env(:arbor_orchestrator, :event_log_backend, ETS)
      configure_historian_target(:durable_event_log_target, durable)
      configure_historian_target(:hot_event_log_target, hot)

      Arbor.Signals.Config.Testing.isolate_namespace()
      Arbor.Signals.Config.Testing.put(:durable_sink_module, Arbor.Historian)

      on_exit(fn ->
        restore_env(:arbor_orchestrator, :event_log_name, originals.event_log_name)
        restore_env(:arbor_orchestrator, :event_log_backend, originals.event_log_backend)
        restore_env(:arbor_historian, :durable_event_log_target, originals.durable)
        restore_env(:arbor_historian, :hot_event_log_target, originals.hot)
      end)

      :ok
    end

    test "a stage_completed carrying a struct in context_updates persists (sanitized), no crash" do
      run_id = "run_test_#{System.unique_integer([:positive])}"

      event =
        Event.stage_completed("llm_node", :success,
          duration_ms: 7,
          context_updates: %{"session.thing" => %Unencodable{ref: make_ref(), note: "audit me"}},
          notes: "completed"
        )
        |> Map.put(:run_id, run_id)

      # The whole point: a struct-bearing enriched event flows through the durable
      # persist path without raising.
      assert :ok = Events.dual_emit(event, run_id: run_id)

      {:ok, events} = Events.read_run_events(run_id)
      persisted = Enum.find(events, &(&1.type == "stage_completed"))

      assert persisted, "the enriched stage_completed event was persisted + queryable"
      thing = persisted.data["context_updates"]["session.thing"]
      assert is_map(thing), "the struct was sanitized to a plain map for durable audit"
      assert thing["note"] == "audit me"
      assert persisted.data["notes"] == "completed"
    end
  end

  describe "C — status.json is gated by :status_files_enabled" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "arbor_statusgate_#{System.unique_integer([:positive])}")
      prev = Application.get_env(:arbor_orchestrator, :status_files_enabled)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:arbor_orchestrator, :status_files_enabled),
          else: Application.put_env(:arbor_orchestrator, :status_files_enabled, prev)

        File.rm_rf(tmp)
      end)

      %{tmp: tmp}
    end

    @gate_dot """
    digraph T {
      start [shape=Mdiamond]
      n [type="transform", transform="identity", source_key="x", output_key="y"]
      done [shape=Msquare]
      start -> n -> done
    }
    """

    test "default (enabled) writes the per-node status.json", %{tmp: tmp} do
      Application.delete_env(:arbor_orchestrator, :status_files_enabled)
      {:ok, g} = Arbor.Orchestrator.compile(@gate_dot)

      assert {:ok, _} =
               Engine.run(g, logs_root: tmp, resumable: false, initial_values: %{"x" => "hi"})

      assert File.exists?(Path.join([tmp, "n", "status.json"]))
    end

    test "disabled retires status.json (durable event stream is the audit record)", %{tmp: tmp} do
      Application.put_env(:arbor_orchestrator, :status_files_enabled, false)
      {:ok, g} = Arbor.Orchestrator.compile(@gate_dot)

      assert {:ok, _} =
               Engine.run(g, logs_root: tmp, resumable: false, initial_values: %{"x" => "hi"})

      refute File.exists?(Path.join([tmp, "n", "status.json"]))
    end
  end

  defp configure_historian_target(key, name) do
    Application.put_env(:arbor_historian, key, %{name: name, backend: ETS, opts: []})
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end

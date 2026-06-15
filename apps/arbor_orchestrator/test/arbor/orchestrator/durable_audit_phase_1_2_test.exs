defmodule Arbor.Orchestrator.DurableAuditPhase12Test do
  @moduledoc """
  Regression tests for the durable-execution-audit work, phases 1–2
  (`.arbor/roadmap/2-planned/durable-execution-audit.md`).

  - **Phase 1 (robustness):** a non-`Jason.Encoder` term in a node's
    `context_updates` must no longer crash the run when `status.json` is written.
    On `HEAD~1` the engine raises `Protocol.UndefinedError` at the status/checkpoint
    `Jason.encode`; here the run completes and the audit dump is sanitized.
  - **Phase 2 (checkpoint = resume-only):** `checkpoint.json` is written only when
    the run is resumable. `resumable: false` (what Session passes for turn/heartbeat)
    writes none; the default still does.
  """
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Handlers.Registry

  @moduletag :fast

  # A struct with NO Jason.Encoder — encoding it raises.
  defmodule Unencodable do
    defstruct [:ref, :note]
  end

  # Returns a non-encodable struct in context_updates, exercising the status.json
  # (and, when resumable, checkpoint.json) JSON-encode path.
  defmodule StructEmittingHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    alias Arbor.Orchestrator.Engine.Outcome

    @impl true
    def idempotency, do: :idempotent

    @impl true
    def execute(_node, _context, _graph, _opts) do
      %Outcome{
        status: :success,
        notes: "emits a non-encodable struct",
        context_updates: %{"session.thing" => %Unencodable{ref: make_ref(), note: "x"}}
      }
    end
  end

  setup do
    snapshot = Registry.snapshot_custom_handlers()
    Registry.register("test.struct_emitter", StructEmittingHandler)
    tmp = Path.join(System.tmp_dir!(), "arbor_audit_test_#{:erlang.unique_integer([:positive])}")

    on_exit(fn ->
      Registry.restore_custom_handlers(snapshot)
      File.rm_rf(tmp)
    end)

    %{tmp: tmp}
  end

  @plain_dot """
  digraph T {
    start [shape=Mdiamond]
    n [type="transform", transform="identity", source_key="x", output_key="y"]
    done [shape=Msquare]
    start -> n -> done
  }
  """

  describe "Phase 2 — checkpoint.json is gated on resumability" do
    test "resumable: false writes no checkpoint.json", %{tmp: tmp} do
      {:ok, graph} = Arbor.Orchestrator.compile(@plain_dot)

      assert {:ok, _} =
               Engine.run(graph, logs_root: tmp, resumable: false, initial_values: %{"x" => "hi"})

      refute File.exists?(Path.join(tmp, "checkpoint.json")),
             "a non-resumable run should not write resume state"
    end

    test "default (resumable: true) still writes checkpoint.json", %{tmp: tmp} do
      {:ok, graph} = Arbor.Orchestrator.compile(@plain_dot)

      assert {:ok, _} = Engine.run(graph, logs_root: tmp, initial_values: %{"x" => "hi"})

      assert File.exists?(Path.join(tmp, "checkpoint.json")),
             "default behavior (resumable) is unchanged"
    end
  end

  describe "Phase 1 — a non-JSON-encodable term no longer crashes the run" do
    @struct_dot """
    digraph T {
      start [shape=Mdiamond]
      emit [type="test.struct_emitter"]
      done [shape=Msquare]
      start -> emit -> done
    }
    """

    test "run completes and status.json is written with a sanitized value", %{tmp: tmp} do
      {:ok, graph} = Arbor.Orchestrator.compile(@struct_dot)

      # resumable: false so checkpoint.json (which would ALSO choke on the struct,
      # and which we deliberately don't lossy-sanitize because it must round-trip
      # for resume) isn't written — isolating the status.json sanitization fix.
      assert {:ok, _} = Engine.run(graph, logs_root: tmp, resumable: false),
             "a non-encodable struct in context_updates must not crash the run"

      status_path = Path.join([tmp, "emit", "status.json"])
      assert File.exists?(status_path)

      {:ok, decoded} = status_path |> File.read!() |> Jason.decode()
      thing = decoded["context_updates"]["session.thing"]

      # The struct was flattened to a JSON-safe map (json_safe/1), not crashed on.
      assert is_map(thing)
      assert thing["note"] == "x"
      # The embedded reference became an inspect string rather than blowing up.
      assert is_binary(thing["ref"])
    end
  end
end

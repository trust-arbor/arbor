defmodule Arbor.Orchestrator.Engine.ContextTaintTest do
  @moduledoc """
  Unit tests for provenance taint storage on the engine Context
  (taint-tracking-rebuild Phase 1 mechanism).
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context

  @moduletag :fast

  describe "record_output_taint/3 and taint_label/2" do
    test "records a provenance level on each output key" do
      ctx =
        %Context{values: %{}}
        |> Context.record_output_taint(["a", "b"], :untrusted)

      assert Context.taint_label(ctx, "a") == :untrusted
      assert Context.taint_label(ctx, "b") == :untrusted
      assert Context.taint_label(ctx, "missing") == nil
    end

    test "a nil level is a no-op (most actions declare no provenance)" do
      ctx = Context.record_output_taint(%Context{values: %{}}, ["a"], nil)
      assert ctx.taint == %{}
    end
  end

  describe "provenance is engine-owned (cannot be laundered via context_updates)" do
    test "apply_updates merges into :values only, never :taint" do
      ctx =
        %Context{values: %{}}
        |> Context.record_output_taint(["secret"], :untrusted)
        # A malicious/buggy node trying to clear its own provenance by writing
        # the key as ordinary output data must NOT affect the taint map.
        |> Context.apply_updates(%{"__taint__" => %{}, "secret" => "laundered"})

      assert Context.taint_label(ctx, "secret") == :untrusted
    end
  end

  describe "worst_taint/2" do
    test "returns the most-tainted level among the given keys" do
      ctx =
        %Context{values: %{}}
        |> Context.record_output_taint(["a"], :derived)
        |> Context.record_output_taint(["b"], :untrusted)
        |> Context.record_output_taint(["c"], :trusted)

      assert Context.worst_taint(ctx, ["a", "b", "c"]) == :untrusted
      assert Context.worst_taint(ctx, ["a", "c"]) == :derived
      assert Context.worst_taint(ctx, ["c"]) == :trusted
    end

    test "hostile outranks untrusted" do
      ctx =
        %Context{values: %{}}
        |> Context.record_output_taint(["a"], :untrusted)
        |> Context.record_output_taint(["b"], :hostile)

      assert Context.worst_taint(ctx, ["a", "b"]) == :hostile
    end

    test "unlabeled keys contribute nothing; all-unlabeled returns nil" do
      ctx = Context.record_output_taint(%Context{values: %{}}, ["a"], :untrusted)

      assert Context.worst_taint(ctx, ["x", "y"]) == nil
      # Mixed: only the labeled key counts.
      assert Context.worst_taint(ctx, ["a", "x"]) == :untrusted
    end
  end
end

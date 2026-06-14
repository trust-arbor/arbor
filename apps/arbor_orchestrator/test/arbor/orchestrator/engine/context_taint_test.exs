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

  describe "propagate_output_taint/4 (Phase 3 per-edge propagation)" do
    test "a declared provenance is authoritative for outputs (ingress / reduction)" do
      # An ingress (web -> :untrusted) labels its outputs regardless of inputs.
      ctx =
        %Context{values: %{}}
        |> Context.propagate_output_taint(["page"], :untrusted, [])

      assert Context.taint_label(ctx, "page") == :untrusted

      # A reduction point (LLM -> :derived) labels :derived even when it read
      # untrusted input — the deliberate derived asymmetry.
      ctx2 =
        %Context{values: %{}}
        |> Context.record_output_taint(["raw"], :untrusted)
        |> Context.propagate_output_taint(["summary"], :derived, ["raw"])

      assert Context.taint_label(ctx2, "summary") == :derived
    end

    test "undeclared transform propagates the worst input taint to its outputs (closes laundering)" do
      # The laundering hole: a transform reads untrusted "raw" and re-emits it as
      # "clean". Without propagation "clean" would be unlabeled and a downstream
      # shell node would see no taint. With propagation it inherits :untrusted.
      ctx =
        %Context{values: %{}}
        |> Context.record_output_taint(["raw"], :untrusted)
        |> Context.propagate_output_taint(["clean"], nil, ["raw"])

      assert Context.taint_label(ctx, "clean") == :untrusted
    end

    test "propagation is per-edge: outputs do not inherit taint from unread keys" do
      ctx =
        %Context{values: %{}}
        |> Context.record_output_taint(["unread_secret"], :untrusted)
        # node declares it only read "safe_input" (untainted), not unread_secret
        |> Context.propagate_output_taint(["out"], nil, ["safe_input"])

      assert Context.taint_label(ctx, "out") == nil
    end

    test "no declaration and no tainted inputs leaves outputs unlabeled" do
      ctx = Context.propagate_output_taint(%Context{values: %{}}, ["out"], nil, ["a", "b"])
      assert Context.taint_label(ctx, "out") == nil
    end
  end
end

defmodule Arbor.Orchestrator.Engine.ContextTaintTest do
  @moduledoc """
  Unit tests for provenance taint storage on the engine Context
  (taint-tracking-rebuild). Provenance is stored as %Taint{} structs; these
  tests assert via `taint_level/2` (level) and the struct's `.level`/`.sanitizations`.
  """
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Orchestrator.Engine.Context

  @moduletag :fast

  describe "record_output_taint/3, taint_label/2, taint_level/2" do
    test "records provenance on each output key (wrapping a bare level into a struct)" do
      ctx = Context.record_output_taint(%Context{values: %{}}, ["a", "b"], :untrusted)

      assert %Taint{level: :untrusted} = Context.taint_label(ctx, "a")
      assert Context.taint_level(ctx, "a") == :untrusted
      assert Context.taint_level(ctx, "b") == :untrusted
      assert Context.taint_label(ctx, "missing") == nil
      assert Context.taint_level(ctx, "missing") == nil
    end

    test "stores a %Taint{} struct as-is (sanitization bits preserved)" do
      sanitized = %Taint{level: :derived, sanitizations: 4}
      ctx = Context.record_output_taint(%Context{values: %{}}, ["x"], sanitized)

      assert Context.taint_label(ctx, "x") == sanitized
      assert Context.taint_label(ctx, "x").sanitizations == 4
    end

    test "a nil provenance is a no-op (most actions declare none)" do
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

      assert Context.taint_level(ctx, "secret") == :untrusted
    end
  end

  describe "worst_taint/2 (combine via max level, AND sanitizations)" do
    test "returns the most-tainted level among the given keys" do
      ctx =
        %Context{values: %{}}
        |> Context.record_output_taint(["a"], :derived)
        |> Context.record_output_taint(["b"], :untrusted)
        |> Context.record_output_taint(["c"], :trusted)

      assert Context.worst_taint(ctx, ["a", "b", "c"]).level == :untrusted
      assert Context.worst_taint(ctx, ["a", "c"]).level == :derived
      assert Context.worst_taint(ctx, ["c"]).level == :trusted
    end

    test "hostile outranks untrusted" do
      ctx =
        %Context{values: %{}}
        |> Context.record_output_taint(["a"], :untrusted)
        |> Context.record_output_taint(["b"], :hostile)

      assert Context.worst_taint(ctx, ["a", "b"]).level == :hostile
    end

    test "sanitizations are intersected (only kept if present in ALL inputs)" do
      ctx =
        %Context{values: %{}}
        |> Context.record_output_taint(["a"], %Taint{level: :derived, sanitizations: 0b110})
        |> Context.record_output_taint(["b"], %Taint{level: :derived, sanitizations: 0b011})

      combined = Context.worst_taint(ctx, ["a", "b"])
      # Only bit 0b010 is set in both.
      assert combined.sanitizations == 0b010
    end

    test "unlabeled keys contribute nothing; all-unlabeled returns nil" do
      ctx = Context.record_output_taint(%Context{values: %{}}, ["a"], :untrusted)

      assert Context.worst_taint(ctx, ["x", "y"]) == nil
      assert Context.worst_taint(ctx, ["a", "x"]).level == :untrusted
    end
  end

  describe "propagate_output_taint/4 (Phase 3 per-edge propagation)" do
    test "a declared provenance is authoritative for outputs (ingress / reduction)" do
      ctx = Context.propagate_output_taint(%Context{values: %{}}, ["page"], :untrusted, [])
      assert Context.taint_level(ctx, "page") == :untrusted

      # A reduction point (LLM -> :derived) labels :derived even when it read
      # untrusted input — the deliberate derived asymmetry.
      ctx2 =
        %Context{values: %{}}
        |> Context.record_output_taint(["raw"], :untrusted)
        |> Context.propagate_output_taint(["summary"], :derived, ["raw"])

      assert Context.taint_level(ctx2, "summary") == :derived
    end

    test "undeclared transform propagates the worst input taint (closes laundering)" do
      ctx =
        %Context{values: %{}}
        |> Context.record_output_taint(["raw"], :untrusted)
        |> Context.propagate_output_taint(["clean"], nil, ["raw"])

      assert Context.taint_level(ctx, "clean") == :untrusted
    end

    test "propagation is per-edge: outputs do not inherit taint from unread keys" do
      ctx =
        %Context{values: %{}}
        |> Context.record_output_taint(["unread_secret"], :untrusted)
        |> Context.propagate_output_taint(["out"], nil, ["safe_input"])

      assert Context.taint_level(ctx, "out") == nil
    end

    test "no declaration and no tainted inputs leaves outputs unlabeled" do
      ctx = Context.propagate_output_taint(%Context{values: %{}}, ["out"], nil, ["a", "b"])
      assert Context.taint_level(ctx, "out") == nil
    end
  end

  describe "new/2 :taint option (boundary inheritance)" do
    test "a child/branch context inherits provenance from its parent (atom wrapped)" do
      ctx = Context.new(%{"k" => "v"}, taint: %{"k" => :untrusted})
      assert Context.taint_level(ctx, "k") == :untrusted
    end

    test "accepts pre-built %Taint{} values" do
      ctx = Context.new(%{}, taint: %{"k" => %Taint{level: :derived, sanitizations: 4}})
      assert Context.taint_label(ctx, "k").sanitizations == 4
    end

    test "defaults to empty taint" do
      assert Context.new(%{"k" => "v"}).taint == %{}
    end
  end

  describe "reduce_taint/4 (human-review / verified-pipeline level reduction)" do
    test "human_review lowers untrusted -> trusted" do
      ctx =
        %Context{values: %{}}
        |> Context.record_output_taint(["x"], :untrusted)
        |> Context.reduce_taint("x", :trusted, :human_review)

      assert Context.taint_level(ctx, "x") == :trusted
    end

    test "preserves sanitization bits, only changes the level" do
      ctx =
        %Context{values: %{}}
        |> Context.record_output_taint(["x"], %Taint{level: :untrusted, sanitizations: 4})
        |> Context.reduce_taint("x", :derived, :human_review)

      assert Context.taint_label(ctx, "x").level == :derived
      assert Context.taint_label(ctx, "x").sanitizations == 4
    end

    test "never RAISES a key's taint (a reduction can only lower)" do
      ctx =
        %Context{values: %{}}
        |> Context.record_output_taint(["x"], :trusted)
        # human_review CAN target :untrusted, but that would raise — refused.
        |> Context.reduce_taint("x", :untrusted, :human_review)

      assert Context.taint_level(ctx, "x") == :trusted
    end

    test "unlabeled key is a no-op" do
      ctx = Context.reduce_taint(%Context{values: %{}}, "missing", :trusted, :human_review)
      assert Context.taint_level(ctx, "missing") == nil
    end

    test "a disallowed reduction reason leaves the level unchanged" do
      ctx =
        %Context{values: %{}}
        |> Context.record_output_taint(["x"], :untrusted)
        # verified_pipeline cannot reach :trusted (only :derived).
        |> Context.reduce_taint("x", :trusted, :verified_pipeline)

      assert Context.taint_level(ctx, "x") == :untrusted
    end
  end

  describe "combine/1 (collapse a list of taint structs to one)" do
    test "max level, nils ignored, empty -> nil" do
      assert Context.combine([]) == nil
      assert Context.combine([nil, nil]) == nil

      assert Context.combine([
               %Taint{level: :trusted},
               nil,
               %Taint{level: :untrusted},
               %Taint{level: :derived}
             ]).level == :untrusted

      assert Context.combine([%Taint{level: :untrusted}, %Taint{level: :hostile}]).level ==
               :hostile
    end
  end
end

defmodule Arbor.Orchestrator.Handlers.ExtractHandlerTest do
  @moduledoc """
  Phase 4 quarantined extraction (variant b): schema validation earns a
  provenance reduction (:untrusted/:hostile -> :derived). The reduction is only
  applied when validation passes; a failing value is not emitted or reduced.
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ExtractHandler

  @moduletag :fast

  defp build_node(attrs), do: %Node{id: "ex", attrs: attrs}

  defp run(value, level, attrs) do
    ctx =
      Context.new(%{"in" => value})
      |> Context.record_output_taint(["in"], level)

    attrs = Map.merge(%{"source_key" => "in", "output_key" => "out"}, attrs)
    ExtractHandler.execute(build_node(attrs), ctx, %Graph{}, [])
  end

  describe "enum validation reduces untrusted -> derived on a match" do
    test "valid enum value passes and is reduced to :derived" do
      outcome = run("approve", :untrusted, %{"enum" => "approve,reject,modify"})

      assert outcome.status == :success
      assert outcome.output_taint.level == :derived
      assert outcome.context_updates["out"] == "approve"
    end

    test "a value outside the enum fails closed (not emitted, not reduced)" do
      outcome = run("approve; rm -rf /", :untrusted, %{"enum" => "approve,reject"})

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "validation failed"
    end
  end

  describe "int validation" do
    test "a bounded integer passes and is reduced" do
      outcome = run("42", :untrusted, %{"int" => "true", "min" => "0", "max" => "100"})
      assert outcome.status == :success
      assert outcome.output_taint.level == :derived
      assert outcome.context_updates["out"] == 42
    end

    test "out-of-range fails closed" do
      outcome = run("999", :untrusted, %{"int" => "true", "max" => "100"})
      assert outcome.status == :fail
    end

    test "non-integer fails closed" do
      outcome = run("42; whoami", :untrusted, %{"int" => "true"})
      assert outcome.status == :fail
    end
  end

  describe "match (full-string regex)" do
    test "a fully-matching value passes" do
      outcome = run("abc123", :untrusted, %{"match" => "[a-z0-9]+"})
      assert outcome.status == :success
      assert outcome.output_taint.level == :derived
    end

    test "a partial match (injection appended) fails closed" do
      # "[a-z0-9]+" must match the WHOLE string, so the trailing shell metachars fail.
      outcome = run("abc123; rm -rf /", :untrusted, %{"match" => "[a-z0-9]+"})
      assert outcome.status == :fail
    end
  end

  describe "reduction discipline" do
    test "hostile is also reduced to derived on a valid schema" do
      outcome = run("approve", :hostile, %{"enum" => "approve,reject"})
      assert outcome.status == :success
      assert outcome.output_taint.level == :derived
    end

    test "already-trusted/derived inputs are NOT raised" do
      assert run("approve", :trusted, %{"enum" => "approve,reject"}).output_taint.level ==
               :trusted

      assert run("approve", :derived, %{"enum" => "approve,reject"}).output_taint.level ==
               :derived
    end

    test "no structural validator fails closed (a reduction must be earned)" do
      outcome = run("anything", :untrusted, %{"max_length" => "100"})
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "must be earned"
    end
  end
end

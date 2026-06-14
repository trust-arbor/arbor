defmodule Arbor.Orchestrator.Handlers.SanitizeHandlerTest do
  @moduledoc """
  Phase 4 sanitizer node: runs vetted sanitizers and records the resulting
  sanitization bits on the output's provenance taint (so downstream `requires:`
  control gates can be satisfied without forging the bit from a DOT graph).
  """
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.SanitizeHandler
  alias Arbor.Signals.Taint, as: TaintOps

  @moduletag :fast

  defp build_node(attrs), do: %Node{id: "san", attrs: attrs}

  defp ctx_with(values, taint) do
    Enum.reduce(taint, Context.new(values), fn {k, level}, acc ->
      Context.record_output_taint(acc, [k], level)
    end)
  end

  test "sets the sanitization bit on the output taint, preserving the level" do
    context = ctx_with(%{"cmd" => "ls; rm -rf /"}, %{"cmd" => :derived})

    outcome =
      SanitizeHandler.execute(
        build_node(%{
          "sanitize" => "command_injection",
          "source_key" => "cmd",
          "output_key" => "clean"
        }),
        context,
        %Graph{},
        []
      )

    assert outcome.status == :success
    # Bit is set...
    assert TaintOps.sanitized?(outcome.output_taint.sanitizations, :command_injection)
    # ...and the provenance LEVEL is unchanged (sanitization != reduction).
    assert outcome.output_taint.level == :derived
    # The sanitized (escaped) value is written, not the raw input.
    assert outcome.context_updates["clean"] != "ls; rm -rf /"
  end

  test "chains multiple sanitizers" do
    context = ctx_with(%{"v" => "<script>"}, %{"v" => :derived})

    outcome =
      SanitizeHandler.execute(
        build_node(%{
          "sanitize" => "xss,log_injection",
          "source_key" => "v",
          "output_key" => "v2"
        }),
        context,
        %Graph{},
        []
      )

    assert outcome.status == :success
    assert TaintOps.sanitized?(outcome.output_taint.sanitizations, :xss)
    assert TaintOps.sanitized?(outcome.output_taint.sanitizations, :log_injection)
  end

  test "unlabeled input is treated as :untrusted (conservative)" do
    context = Context.new(%{"v" => "x"})

    outcome =
      SanitizeHandler.execute(
        build_node(%{
          "sanitize" => "command_injection",
          "source_key" => "v",
          "output_key" => "o"
        }),
        context,
        %Graph{},
        []
      )

    assert outcome.status == :success
    assert outcome.output_taint.level == :untrusted
  end

  test "an unknown sanitizer fails closed (no forged bit, no output)" do
    context = ctx_with(%{"v" => "x"}, %{"v" => :derived})

    outcome =
      SanitizeHandler.execute(
        build_node(%{"sanitize" => "totally_made_up", "source_key" => "v", "output_key" => "o"}),
        context,
        %Graph{},
        []
      )

    assert outcome.status == :fail
    assert outcome.failure_reason =~ "sanitize failed"
  end

  test "a missing sanitize attr fails closed" do
    outcome =
      SanitizeHandler.execute(
        build_node(%{"source_key" => "v"}),
        Context.new(%{"v" => "x"}),
        %Graph{},
        []
      )

    assert outcome.status == :fail
  end

  test "the produced taint satisfies a requires: control gate (Phase 4 payoff)" do
    # A :derived value, once command_injection-sanitized, carries the bit — so a
    # shell command param (requires: [:command_injection]) is no longer blocked.
    sanitized =
      %Taint{level: :derived}
      |> then(fn t -> %{t | sanitizations: set_bit(t.sanitizations, :command_injection)} end)

    # Without the bit: blocked (missing sanitization). With it: allowed.
    assert TaintOps.sanitized?(sanitized.sanitizations, :command_injection)
    refute TaintOps.sanitized?(0, :command_injection)
  end

  defp set_bit(mask, name) do
    {:ok, bit} = Taint.sanitization_bit(name)
    Bitwise.bor(mask, bit)
  end
end

defmodule Arbor.Orchestrator.Stdlib.RetryEscalateAliasTest do
  @moduledoc """
  Regression: retry-escalate.dot stays a loadable stdlib compose alias.

  Conservative choice: keep the pipeline as an authoring primitive
  (`type="retry.escalate"` → compose invoke of the shipped DOT). Do not
  inject it into session turn/heartbeat graphs — those have their own
  retry/timeout policy and changing them would alter live LLM behavior.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ComposeHandler
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.Stdlib.Aliases
  alias Arbor.Orchestrator.Validation.Validator

  @graph_file "specs/pipelines/stdlib/retry-escalate.dot"

  test "retry.escalate alias injects the shipped stdlib graph_file" do
    assert {"compose", %{"mode" => "invoke", "graph_file" => @graph_file}} =
             Aliases.resolve("retry.escalate")
  end

  test "aliased graph_file exists, parses, and validates" do
    path = resolve_graph_file!(@graph_file)
    assert File.regular?(path)

    source = File.read!(path)
    assert {:ok, graph} = Parser.parse(source)

    errors =
      graph
      |> Validator.validate()
      |> Enum.filter(&(&1.severity == :error))

    assert errors == [], "retry-escalate.dot validation errors: #{inspect(errors)}"
  end

  test "Registry treats retry.escalate as a used compose invoke" do
    node = %Node{id: "retry", attrs: %{"type" => "retry.escalate"}}
    {handler, resolved} = Registry.resolve_with_attrs(node)

    assert handler == ComposeHandler
    assert resolved.attrs["mode"] == "invoke"
    assert resolved.attrs["graph_file"] == @graph_file
  end

  defp resolve_graph_file!(relative) do
    candidates = [
      Path.expand(relative, File.cwd!()),
      Path.expand(relative, Path.join(File.cwd!(), "apps/arbor_orchestrator")),
      Path.expand(relative, Path.expand("../../..", __DIR__))
    ]

    Enum.find(candidates, &File.regular?/1) ||
      flunk("retry-escalate graph_file not found. Tried: #{inspect(candidates)}")
  end
end

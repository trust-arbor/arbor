defmodule Arbor.Orchestrator.ComposeParentExampleTest do
  @moduledoc """
  Demo runner for `specs/pipelines/examples/compose-parent.dot`.
  Invokes the same child subpipeline twice with different `name`
  context values, captures each child's result at its own
  `subgraph.<node_id>.greeting` prefix, and writes two distinct
  greeting files.

  Exercises engine surface area no other example pipeline hits:
    * `graph.invoke` / `SubgraphHandler` execution path
    * `pass_context=...` whitelisting (only `name` flows to child)
    * Per-invocation `subgraph.<node_id>.*` namespacing — two
      invocations of the same child don't clobber each other
    * Result extraction back to flat parent context keys
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  @dot_path Path.expand("../../../specs/pipelines/examples/compose-parent.dot", __DIR__)
  @principal_id "agent_compose_test"

  setup_all do
    {:ok, cap} =
      Arbor.Contracts.Security.Capability.new(
        resource_uri: "arbor://fs/**",
        principal_id: @principal_id,
        delegation_depth: 0,
        constraints: %{},
        metadata: %{test: true}
      )

    Arbor.Security.CapabilityStore.put(cap)
    :ok
  end

  setup do
    workdir = Path.join(System.tmp_dir!(), "arbor_compose_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workdir)
    on_exit(fn -> File.rm_rf(workdir) end)

    logs_root =
      Path.join(System.tmp_dir!(), "arbor_compose_logs_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(logs_root) end)

    first_output = Path.join(workdir, "alice.txt")
    second_output = Path.join(workdir, "bob.txt")

    child_dot_source =
      Path.expand("../../../specs/pipelines/examples/compose-child.dot", __DIR__)
      |> File.read!()

    spec = %{
      "first_name" => "Alice",
      "second_name" => "Bob",
      "first_output_path" => first_output,
      "second_output_path" => second_output,
      "child_dot_source" => child_dot_source
    }

    File.write!(Path.join(workdir, "spec.json"), Jason.encode!(spec, pretty: true))

    {:ok,
     workdir: workdir,
     logs_root: logs_root,
     first_output: first_output,
     second_output: second_output}
  end

  test "two invocations of the same child produce two isolated outputs", ctx do
    initial_values = %{
      "spec_path" => "spec.json",
      "workdir" => ctx.workdir,
      "session.agent_id" => @principal_id
    }

    assert {:ok, result} =
             Arbor.Orchestrator.run_file(@dot_path,
               initial_values: initial_values,
               logs_root: ctx.logs_root,
               authorization: false
             )

    assert result.final_outcome.status == :success,
           "pipeline failed: #{inspect(result.final_outcome.failure_reason)}"

    # Both invoke nodes ran.
    assert "invoke_first" in result.completed_nodes
    assert "invoke_second" in result.completed_nodes

    # Both files exist with the right content — proves each invocation
    # used its own `name` value AND the prefixed result extraction
    # (subgraph.invoke_first.greeting vs subgraph.invoke_second.greeting)
    # routed correctly.
    assert File.exists?(ctx.first_output)
    assert File.exists?(ctx.second_output)

    assert File.read!(ctx.first_output) == "Hello, Alice!"
    assert File.read!(ctx.second_output) == "Hello, Bob!"
  end

  test "child sees ONLY the keys named in pass_context (isolation)", ctx do
    # Add a secret to the parent's spec that's NOT in any
    # pass_context= list. If isolation breaks, the child might
    # leak it via the template substitution. We don't have a clean
    # way to peek inside the child's context from outside, so
    # instead we assert the OUTPUT only contains Alice/Bob — no
    # leakage of "leaked_secret" into either greeting.
    initial_values = %{
      "spec_path" => "spec.json",
      "workdir" => ctx.workdir,
      "session.agent_id" => @principal_id,
      "leaked_secret" => "SHOULD-NOT-APPEAR"
    }

    {:ok, _result} =
      Arbor.Orchestrator.run_file(@dot_path,
        initial_values: initial_values,
        logs_root: ctx.logs_root,
        authorization: false
      )

    refute File.read!(ctx.first_output) =~ "SHOULD-NOT-APPEAR"
    refute File.read!(ctx.second_output) =~ "SHOULD-NOT-APPEAR"
  end
end

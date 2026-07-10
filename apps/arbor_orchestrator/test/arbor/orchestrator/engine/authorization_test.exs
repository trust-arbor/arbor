defmodule Arbor.Orchestrator.Engine.AuthorizationTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.{Authorization, Context, Outcome, RunAuthorization}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node

  @graph %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

  describe "authorize_and_execute/5 with authorization disabled" do
    test "calls handler directly when authorization opt is absent" do
      handler = stub_handler(:success, "executed")
      node = %Node{id: "build", attrs: %{"type" => "codergen"}}

      outcome = Authorization.authorize_and_execute(handler, node, Context.new(), @graph, [])

      assert outcome.status == :success
      assert outcome.notes == "executed"
    end

    test "calls handler directly when authorization: false" do
      handler = stub_handler(:success, "ran")
      node = %Node{id: "deploy", attrs: %{"type" => "tool"}}
      opts = [authorization: false]

      outcome = Authorization.authorize_and_execute(handler, node, Context.new(), @graph, opts)

      assert outcome.status == :success
      assert outcome.notes == "ran"
    end

    test "works with module handlers" do
      node = %Node{id: "start", attrs: %{"shape" => "Mdiamond"}}

      outcome =
        Authorization.authorize_and_execute(
          Arbor.Orchestrator.Handlers.StartHandler,
          node,
          Context.new(),
          @graph,
          []
        )

      assert outcome.status == :success
    end
  end

  describe "authorize_and_execute/5 with authorization enabled" do
    test "allows execution when authorizer returns :ok" do
      handler = stub_handler(:success, "authorized run")
      authorizer = fn _agent_id, _type -> :ok end
      node = %Node{id: "build", attrs: %{"type" => "codergen"}}
      ctx = Context.new(%{"session.agent_id" => "agent_abc"})
      opts = auth_opts("agent_abc", authorizer)

      outcome = Authorization.authorize_and_execute(handler, node, ctx, @graph, opts)

      assert outcome.status == :success
      assert outcome.notes == "authorized run"
    end

    test "blocks execution when authorizer returns error" do
      handler = stub_handler(:success, "should not run")
      authorizer = fn _agent_id, _type -> {:error, "insufficient privileges"} end
      node = %Node{id: "deploy", attrs: %{"type" => "tool"}}
      ctx = Context.new(%{"session.agent_id" => "agent_untrusted"})
      opts = auth_opts("agent_untrusted", authorizer)

      outcome = Authorization.authorize_and_execute(handler, node, ctx, @graph, opts)

      assert outcome.status == :fail
      assert outcome.failure_reason == "unauthorized: tool for agent agent_untrusted"
    end

    test "fails when authorization enabled but no authorizer provided" do
      handler = stub_handler(:success, "should not run")
      node = %Node{id: "build", attrs: %{"type" => "codergen"}}
      ctx = Context.new(%{"session.agent_id" => "agent_abc"})
      opts = auth_opts("agent_abc")

      outcome = Authorization.authorize_and_execute(handler, node, ctx, @graph, opts)

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "unauthorized"
    end

    test "passes agent_id and handler type to authorizer" do
      test_pid = self()

      authorizer = fn agent_id, handler_type ->
        send(test_pid, {:auth_check, agent_id, handler_type})
        :ok
      end

      handler = stub_handler(:success)
      node = %Node{id: "x", attrs: %{"type" => "file.write"}}
      ctx = Context.new(%{"session.agent_id" => "agent_42"})
      opts = auth_opts("agent_42", authorizer)

      Authorization.authorize_and_execute(handler, node, ctx, @graph, opts)

      assert_received {:auth_check, "agent_42", "file.write"}
    end

    test "authorizer receives immutable agent_id when context is empty" do
      test_pid = self()

      authorizer = fn agent_id, _type ->
        send(test_pid, {:agent, agent_id})
        :ok
      end

      handler = stub_handler(:success)
      node = %Node{id: "x", attrs: %{"type" => "codergen"}}
      opts = auth_opts("agent_abc", authorizer)

      Authorization.authorize_and_execute(handler, node, Context.new(), @graph, opts)

      assert_received {:agent, "agent_abc"}
    end
  end

  describe "start/exit nodes bypass authorization" do
    test "start nodes are always authorized" do
      handler = stub_handler(:success, "start ok")
      authorizer = fn _a, _t -> {:error, "always deny"} end
      node = %Node{id: "start", attrs: %{"shape" => "Mdiamond"}}
      ctx = Context.new(%{"session.agent_id" => "agent_abc"})
      opts = auth_opts("agent_abc", authorizer)

      outcome = Authorization.authorize_and_execute(handler, node, ctx, @graph, opts)

      assert outcome.status == :success
      assert outcome.notes == "start ok"
    end

    test "exit nodes are always authorized" do
      handler = stub_handler(:success, "exit ok")
      authorizer = fn _a, _t -> {:error, "always deny"} end
      node = %Node{id: "done", attrs: %{"type" => "exit"}}
      ctx = Context.new(%{"session.agent_id" => "agent_abc"})
      opts = auth_opts("agent_abc", authorizer)

      outcome = Authorization.authorize_and_execute(handler, node, ctx, @graph, opts)

      assert outcome.status == :success
      assert outcome.notes == "exit ok"
    end

    test "start node detected by shape attribute" do
      handler = stub_handler(:success, "ok")
      authorizer = fn _a, _t -> {:error, "deny"} end
      node = %Node{id: "entry", attrs: %{"shape" => "Mdiamond"}}
      ctx = Context.new(%{"session.agent_id" => "agent_abc"})
      opts = auth_opts("agent_abc", authorizer)

      outcome = Authorization.authorize_and_execute(handler, node, ctx, @graph, opts)
      assert outcome.status == :success
    end

    test "exit node detected by type attribute" do
      handler = stub_handler(:success, "ok")
      authorizer = fn _a, _t -> {:error, "deny"} end
      node = %Node{id: "fin", attrs: %{"type" => "exit"}}
      ctx = Context.new(%{"session.agent_id" => "agent_abc"})
      opts = auth_opts("agent_abc", authorizer)

      outcome = Authorization.authorize_and_execute(handler, node, ctx, @graph, opts)
      assert outcome.status == :success
    end
  end

  describe "required_capability/1" do
    test "returns nil for start nodes" do
      node = %Node{id: "s", attrs: %{"shape" => "Mdiamond"}}
      assert Authorization.required_capability(node) == nil
    end

    test "returns nil for exit nodes" do
      node = %Node{id: "e", attrs: %{"type" => "exit"}}
      assert Authorization.required_capability(node) == nil
    end

    test "returns capability URI for codergen nodes" do
      node = %Node{id: "b", attrs: %{"type" => "codergen"}}
      assert Authorization.required_capability(node) == "orchestrator:handler:codergen"
    end

    test "returns capability URI for tool nodes" do
      node = %Node{id: "t", attrs: %{"type" => "tool"}}
      assert Authorization.required_capability(node) == "orchestrator:handler:tool"
    end

    test "returns capability URI for file.write nodes" do
      node = %Node{id: "fw", attrs: %{"type" => "file.write"}}
      assert Authorization.required_capability(node) == "orchestrator:handler:file.write"
    end

    test "returns capability URI for pipeline.run nodes" do
      node = %Node{id: "pr", attrs: %{"type" => "pipeline.run"}}
      assert Authorization.required_capability(node) == "orchestrator:handler:pipeline.run"
    end

    test "returns capability URI based on shape when no type attr" do
      node = %Node{id: "c", attrs: %{"shape" => "diamond"}}
      assert Authorization.required_capability(node) == "orchestrator:handler:conditional"
    end

    test "defaults to codergen for plain box nodes" do
      node = %Node{id: "plain", attrs: %{}}
      assert Authorization.required_capability(node) == "orchestrator:handler:codergen"
    end
  end

  # --- Helpers ---

  defp stub_handler(status, notes \\ nil) do
    fn _node, _context, _graph, _opts ->
      %Outcome{status: status, notes: notes}
    end
  end

  defp auth_opts(principal, authorizer \\ nil) do
    {:ok, authority} =
      RunAuthorization.new(@graph, agent_id: principal, workdir: File.cwd!())

    [
      authorization: true,
      agent_id: principal,
      run_authorization: authority
    ]
    |> then(fn opts ->
      if authorizer, do: Keyword.put(opts, :authorizer, authorizer), else: opts
    end)
  end
end

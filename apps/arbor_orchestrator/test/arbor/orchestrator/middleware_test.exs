defmodule Arbor.Orchestrator.MiddlewareTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Middleware
  alias Arbor.Orchestrator.Middleware.{Chain, Token}

  # Test middleware modules
  defmodule PassThrough do
    use Arbor.Orchestrator.Middleware
  end

  defmodule AddAssign do
    use Arbor.Orchestrator.Middleware

    @impl true
    def before_node(token) do
      Token.assign(token, :visited, true)
    end
  end

  defmodule HaltBefore do
    use Arbor.Orchestrator.Middleware

    @impl true
    def before_node(token) do
      Middleware.halt(token, "blocked by HaltBefore")
    end
  end

  defmodule HaltAfter do
    use Arbor.Orchestrator.Middleware

    @impl true
    def after_node(token) do
      Middleware.halt(token, "blocked by HaltAfter")
    end
  end

  defmodule TrackOrder do
    use Arbor.Orchestrator.Middleware

    @impl true
    def before_node(token) do
      order = Map.get(token.assigns, :order, [])
      Token.assign(token, :order, order ++ [:before_track])
    end

    @impl true
    def after_node(token) do
      order = Map.get(token.assigns, :order, [])
      Token.assign(token, :order, order ++ [:after_track])
    end
  end

  defmodule TrackOrder2 do
    use Arbor.Orchestrator.Middleware

    @impl true
    def before_node(token) do
      order = Map.get(token.assigns, :order, [])
      Token.assign(token, :order, order ++ [:before_track2])
    end

    @impl true
    def after_node(token) do
      order = Map.get(token.assigns, :order, [])
      Token.assign(token, :order, order ++ [:after_track2])
    end
  end

  defp make_token(attrs \\ %{}) do
    node = %Node{id: "test_node", attrs: attrs}
    context = Context.new()
    graph = %Graph{id: "test", attrs: %{}}

    %Token{
      node: node,
      context: context,
      graph: graph,
      logs_root: "/tmp/test"
    }
  end

  describe "Middleware behaviour" do
    test "default middleware passes through unchanged" do
      token = make_token()
      assert PassThrough.before_node(token) == token
      assert PassThrough.after_node(token) == token
    end

    test "middleware can modify token assigns" do
      token = make_token()
      result = AddAssign.before_node(token)
      assert result.assigns[:visited] == true
    end

    test "middleware can halt execution" do
      token = make_token()
      result = HaltBefore.before_node(token)
      assert result.halted == true
      assert result.halt_reason == "blocked by HaltBefore"
    end
  end

  describe "Token" do
    test "assign/3 adds to assigns map" do
      token = make_token() |> Token.assign(:key, "value")
      assert token.assigns[:key] == "value"
    end

    test "multiple assigns accumulate" do
      token =
        make_token()
        |> Token.assign(:a, 1)
        |> Token.assign(:b, 2)

      assert token.assigns[:a] == 1
      assert token.assigns[:b] == 2
    end

    test "halt/2 sets halted and reason" do
      token = make_token() |> Token.halt("stopped")
      assert token.halted == true
      assert token.halt_reason == "stopped"
    end

    test "halt/3 sets halted, reason, and outcome" do
      outcome = %Outcome{status: :fail, failure_reason: "custom"}
      token = make_token() |> Token.halt("stopped", outcome)
      assert token.halted == true
      assert token.outcome == outcome
    end

    test "initial state has no halt and empty assigns" do
      token = make_token()
      assert token.halted == false
      assert token.halt_reason == ""
      assert token.assigns == %{}
      assert token.outcome == nil
    end
  end

  @mandatory_chain Chain.default_mandatory_chain()

  describe "Chain.build/3" do
    test "mandatory middleware included when no other middleware configured" do
      graph = %Graph{id: "test", attrs: %{}}
      node = %Node{id: "test", attrs: %{}}
      assert Chain.build([], graph, node) == @mandatory_chain
    end

    test "includes engine-level middleware after mandatory" do
      graph = %Graph{id: "test", attrs: %{}}
      node = %Node{id: "test", attrs: %{}}
      chain = Chain.build([middleware: [PassThrough]], graph, node)
      assert chain == @mandatory_chain ++ [PassThrough]
    end

    test "includes graph-level middleware from attrs" do
      Chain.register("test_pass", PassThrough)
      graph = %Graph{id: "test", attrs: %{"middleware" => "test_pass"}}
      node = %Node{id: "test", attrs: %{}}
      chain = Chain.build([], graph, node)
      assert PassThrough in chain
    end

    test "includes node-level middleware from attrs" do
      Chain.register("test_add", AddAssign)
      graph = %Graph{id: "test", attrs: %{}}
      node = %Node{id: "test", attrs: %{"middleware" => "test_add"}}
      chain = Chain.build([], graph, node)
      assert AddAssign in chain
    end

    test "skip_middleware removes from chain" do
      Chain.register("test_skip_target", PassThrough)
      graph = %Graph{id: "test", attrs: %{"middleware" => "test_skip_target"}}
      node = %Node{id: "test", attrs: %{"skip_middleware" => "test_skip_target"}}
      chain = Chain.build([], graph, node)
      # Mandatory chain remains; only the skipped one is removed
      assert chain == @mandatory_chain
    end

    test "combines all three layers" do
      Chain.register("test_graph_mw", TrackOrder)
      Chain.register("test_node_mw", TrackOrder2)
      graph = %Graph{id: "test", attrs: %{"middleware" => "test_graph_mw"}}
      node = %Node{id: "test", attrs: %{"middleware" => "test_node_mw"}}
      chain = Chain.build([middleware: [PassThrough]], graph, node)
      assert chain == @mandatory_chain ++ [PassThrough, TrackOrder, TrackOrder2]
    end

    test "deduplicates middleware" do
      Chain.register("test_dedup", PassThrough)
      graph = %Graph{id: "test", attrs: %{"middleware" => "test_dedup"}}
      node = %Node{id: "test", attrs: %{}}
      chain = Chain.build([middleware: [PassThrough]], graph, node)
      assert chain == @mandatory_chain ++ [PassThrough]
    end

    test "handles nil node" do
      graph = %Graph{id: "test", attrs: %{}}
      chain = Chain.build([middleware: [PassThrough]], graph, nil)
      assert chain == @mandatory_chain ++ [PassThrough]
    end

    test "handles multiple comma-separated middleware names" do
      Chain.register("test_multi_a", TrackOrder)
      Chain.register("test_multi_b", TrackOrder2)
      graph = %Graph{id: "test", attrs: %{}}
      node = %Node{id: "test", attrs: %{"middleware" => "test_multi_a, test_multi_b"}}
      chain = Chain.build([], graph, node)
      assert chain == @mandatory_chain ++ [TrackOrder, TrackOrder2]
    end
  end

  describe "Chain.run_before/2" do
    test "runs middleware in order" do
      token = make_token()
      chain = [TrackOrder, TrackOrder2]
      result = Chain.run_before(chain, token)
      assert result.assigns[:order] == [:before_track, :before_track2]
    end

    test "stops on halt" do
      token = make_token()
      chain = [HaltBefore, TrackOrder]
      result = Chain.run_before(chain, token)
      assert result.halted == true
      # TrackOrder should NOT have run
      refute Map.has_key?(result.assigns, :order)
    end

    test "creates failure outcome when halted without outcome" do
      token = make_token()
      chain = [HaltBefore]
      result = Chain.run_before(chain, token)
      assert result.outcome.status == :fail
      assert result.outcome.failure_reason == "blocked by HaltBefore"
    end

    test "preserves custom outcome when halted with outcome" do
      defmodule HaltWithOutcome do
        use Arbor.Orchestrator.Middleware

        @impl true
        def before_node(token) do
          Token.halt(token, "custom halt", %Outcome{
            status: :fail,
            failure_reason: "custom reason"
          })
        end
      end

      token = make_token()
      chain = [HaltWithOutcome]
      result = Chain.run_before(chain, token)
      assert result.outcome.failure_reason == "custom reason"
    end

    test "returns unmodified token when chain is empty" do
      token = make_token()
      result = Chain.run_before([], token)
      assert result == token
    end
  end

  describe "Chain.run_after/2" do
    test "runs middleware in reverse order" do
      outcome = %Outcome{status: :success}
      token = %{make_token() | outcome: outcome}
      chain = [TrackOrder, TrackOrder2]
      result = Chain.run_after(chain, token)
      # Reverse: TrackOrder2 runs first, then TrackOrder
      assert result.assigns[:order] == [:after_track2, :after_track]
    end

    test "stops on halt in after phase" do
      outcome = %Outcome{status: :success}
      token = %{make_token() | outcome: outcome}
      chain = [TrackOrder, HaltAfter]
      result = Chain.run_after(chain, token)
      assert result.halted == true
      # HaltAfter runs first (reverse), TrackOrder should NOT have run
      refute Map.has_key?(result.assigns, :order)
    end

    test "creates failure outcome when halted and outcome unchanged" do
      outcome = %Outcome{status: :success}
      token = %{make_token() | outcome: outcome}
      chain = [HaltAfter]
      result = Chain.run_after(chain, token)
      assert result.halted == true
      assert result.outcome.status == :fail
      assert result.outcome.failure_reason == "blocked by HaltAfter"
    end

    test "returns unmodified token when chain is empty" do
      outcome = %Outcome{status: :success}
      token = %{make_token() | outcome: outcome}
      result = Chain.run_after([], token)
      assert result == token
    end
  end

  describe "SecretScan middleware" do
    alias Arbor.Orchestrator.Middleware.SecretScan

    test "passes through when no secrets detected" do
      outcome = %Outcome{
        status: :success,
        context_updates: %{"response" => "Hello, how can I help?"}
      }

      token = %{make_token() | outcome: outcome}
      result = SecretScan.after_node(token)
      refute result.halted
    end

    test "detects AWS key in context_updates" do
      outcome = %Outcome{
        status: :success,
        context_updates: %{"response" => "Your key is AKIAIOSFODNN7EXAMPLE"}
      }

      token = %{make_token() | outcome: outcome}
      result = SecretScan.after_node(token)
      assert result.halted
      assert result.halt_reason =~ "Secret scan failed"
      assert result.outcome.status == :fail
    end

    test "detects GitHub PAT in context_updates" do
      outcome = %Outcome{
        status: :success,
        context_updates: %{"output" => "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"}
      }

      token = %{make_token() | outcome: outcome}
      result = SecretScan.after_node(token)
      assert result.halted
    end

    test "detects secrets in last_response context" do
      context = Context.new(%{"last_response" => "Here is key AKIAIOSFODNN7EXAMPLE"})

      outcome = %Outcome{
        status: :success,
        context_updates: %{}
      }

      token = %{make_token() | outcome: outcome, context: context}
      result = SecretScan.after_node(token)
      assert result.halted
    end

    test "warn mode appends to notes instead of halting" do
      outcome = %Outcome{
        status: :success,
        notes: "existing note",
        context_updates: %{"response" => "AKIAIOSFODNN7EXAMPLE"}
      }

      token = %{make_token() | outcome: outcome}
      token = Token.assign(token, :secret_scan_action, :warn)
      result = SecretScan.after_node(token)
      refute result.halted
      assert result.outcome.notes =~ "SECRET WARN"
      assert result.outcome.notes =~ "existing note"
    end

    test "warn mode handles nil notes" do
      outcome = %Outcome{
        status: :success,
        notes: nil,
        context_updates: %{"response" => "AKIAIOSFODNN7EXAMPLE"}
      }

      token = %{make_token() | outcome: outcome}
      token = Token.assign(token, :secret_scan_action, :warn)
      result = SecretScan.after_node(token)
      refute result.halted
      assert result.outcome.notes =~ "SECRET WARN"
    end

    test "redact mode replaces secrets with [REDACTED]" do
      outcome = %Outcome{
        status: :success,
        context_updates: %{"response" => "Key: AKIAIOSFODNN7EXAMPLE done"}
      }

      token = %{make_token() | outcome: outcome}
      token = Token.assign(token, :secret_scan_action, :redact)
      result = SecretScan.after_node(token)
      refute result.halted
      assert result.outcome.context_updates["response"] =~ "[REDACTED]"
      refute result.outcome.context_updates["response"] =~ "AKIAIOSFODNN7EXAMPLE"
    end

    test "redact mode preserves non-string values" do
      outcome = %Outcome{
        status: :success,
        context_updates: %{
          "response" => "AKIAIOSFODNN7EXAMPLE",
          "count" => 42,
          "flag" => true
        }
      }

      token = %{make_token() | outcome: outcome}
      token = Token.assign(token, :secret_scan_action, :redact)
      result = SecretScan.after_node(token)
      assert result.outcome.context_updates["count"] == 42
      assert result.outcome.context_updates["flag"] == true
    end

    test "skips when outcome is nil" do
      token = make_token()
      result = SecretScan.after_node(token)
      refute result.halted
    end

    test "skips when outcome is failure" do
      outcome = %Outcome{status: :fail, failure_reason: "already failed"}
      token = %{make_token() | outcome: outcome}
      result = SecretScan.after_node(token)
      refute result.halted
    end

    test "skips when outcome is retry" do
      outcome = %Outcome{status: :retry}
      token = %{make_token() | outcome: outcome}
      result = SecretScan.after_node(token)
      refute result.halted
    end

    test "skips when outcome is skipped" do
      outcome = %Outcome{status: :skipped}
      token = %{make_token() | outcome: outcome}
      result = SecretScan.after_node(token)
      refute result.halted
    end

    test "before_node is a no-op" do
      token = make_token()
      assert SecretScan.before_node(token) == token
    end

    test "accepts extra patterns via assigns" do
      outcome = %Outcome{
        status: :success,
        context_updates: %{"response" => "ARBOR_SECRET_xyz123abc456"}
      }

      token = %{make_token() | outcome: outcome}

      token =
        Token.assign(token, :secret_scan_extra_patterns, [
          {~r/ARBOR_SECRET_[a-zA-Z0-9]+/, "Arbor Secret"}
        ])

      result = SecretScan.after_node(token)
      assert result.halted
      assert result.halt_reason =~ "Arbor Secret"
    end

    test "detects database connection string" do
      outcome = %Outcome{
        status: :success,
        context_updates: %{
          "config" => "postgres://admin:password123@prod-db.example.com:5432/myapp"
        }
      }

      token = %{make_token() | outcome: outcome}
      result = SecretScan.after_node(token)
      assert result.halted
      assert result.outcome.failure_reason =~ "Database Connection String"
    end

    test "detects private key" do
      outcome = %Outcome{
        status: :success,
        context_updates: %{
          "output" =>
            "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAK...\n-----END RSA PRIVATE KEY-----"
        }
      }

      token = %{make_token() | outcome: outcome}
      result = SecretScan.after_node(token)
      assert result.halted
    end

    test "handles partial_success status" do
      outcome = %Outcome{
        status: :partial_success,
        context_updates: %{"response" => "AKIAIOSFODNN7EXAMPLE"}
      }

      token = %{make_token() | outcome: outcome}
      result = SecretScan.after_node(token)
      assert result.halted
    end
  end

  describe "Engine integration" do
    alias Arbor.Orchestrator.Engine.Authorization

    test "middleware runs around handler when configured" do
      Chain.register("test_track_integration", TrackOrder)

      handler = fn _node, _ctx, _graph, _opts ->
        %Outcome{status: :success, notes: "handler ran"}
      end

      node = %Node{id: "test", attrs: %{"middleware" => "test_track_integration"}}
      context = Context.new()
      graph = %Graph{id: "test", attrs: %{}}

      outcome = Authorization.authorize_and_execute(handler, node, context, graph, [])
      assert outcome.status == :success
      assert outcome.notes == "handler ran"
    end

    test "halting middleware prevents handler execution" do
      Chain.register("test_halt_integration", HaltBefore)

      handler_called = :counters.new(1, [:atomics])

      handler = fn _node, _ctx, _graph, _opts ->
        :counters.add(handler_called, 1, 1)
        %Outcome{status: :success}
      end

      node = %Node{id: "test", attrs: %{"middleware" => "test_halt_integration"}}
      context = Context.new()
      graph = %Graph{id: "test", attrs: %{}}

      outcome = Authorization.authorize_and_execute(handler, node, context, graph, [])
      assert outcome.status == :fail
      assert :counters.get(handler_called, 1) == 0
    end

    test "engine-level middleware applies to all nodes" do
      handler = fn _node, _ctx, _graph, _opts ->
        %Outcome{status: :success}
      end

      node = %Node{id: "test", attrs: %{}}
      context = Context.new()
      graph = %Graph{id: "test", attrs: %{}}

      # HaltBefore should prevent execution
      outcome =
        Authorization.authorize_and_execute(handler, node, context, graph,
          middleware: [HaltBefore]
        )

      assert outcome.status == :fail
    end

    test "after middleware can modify outcome" do
      defmodule AddNoteMiddleware do
        use Arbor.Orchestrator.Middleware

        @impl true
        def after_node(token) do
          existing_notes = token.outcome.notes || ""
          updated = %{token.outcome | notes: existing_notes <> " [middleware ran]"}
          %{token | outcome: updated}
        end
      end

      Chain.register("test_add_note", AddNoteMiddleware)

      handler = fn _node, _ctx, _graph, _opts ->
        %Outcome{status: :success, notes: "original"}
      end

      node = %Node{id: "test", attrs: %{"middleware" => "test_add_note"}}
      context = Context.new()
      graph = %Graph{id: "test", attrs: %{}}

      outcome = Authorization.authorize_and_execute(handler, node, context, graph, [])
      assert outcome.status == :success
      assert outcome.notes =~ "original"
      assert outcome.notes =~ "[middleware ran]"
    end

    test "no middleware means zero overhead path" do
      handler = fn _node, _ctx, _graph, _opts ->
        %Outcome{status: :success, notes: "direct"}
      end

      node = %Node{id: "test", attrs: %{}}
      context = Context.new()
      graph = %Graph{id: "test", attrs: %{}}

      outcome = Authorization.authorize_and_execute(handler, node, context, graph, [])
      assert outcome.status == :success
      assert outcome.notes == "direct"
    end

    test "secret scan middleware catches secrets in handler output" do
      Chain.register("secret_scan_integration", Arbor.Orchestrator.Middleware.SecretScan)

      handler = fn _node, _ctx, _graph, _opts ->
        %Outcome{
          status: :success,
          context_updates: %{"response" => "Here is key AKIAIOSFODNN7EXAMPLE"}
        }
      end

      node = %Node{id: "test", attrs: %{"middleware" => "secret_scan_integration"}}
      context = Context.new()
      graph = %Graph{id: "test", attrs: %{}}

      outcome = Authorization.authorize_and_execute(handler, node, context, graph, [])
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "Secrets detected"
    end
  end
end

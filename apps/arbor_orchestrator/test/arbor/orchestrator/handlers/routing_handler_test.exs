defmodule Arbor.Orchestrator.Handlers.RoutingHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.RoutingHandler

  # Fabricated graph — handler doesn't use it
  @graph %Arbor.Orchestrator.Graph{id: "test", nodes: %{}, edges: []}

  describe "execute/4 — routing.select" do
    test "selects first available candidate" do
      node = select_node([["anthropic", "opus"], ["anthropic", "sonnet"]])

      context =
        Context.new(%{
          "tier" => "critical",
          "avail_anthropic" => "true",
          "trust_anthropic" => "true",
          "quota_anthropic" => "true"
        })

      assert %Outcome{
               status: :success,
               context_updates: %{
                 "selected_backend" => "anthropic",
                 "selected_model" => "opus"
               }
             } = RoutingHandler.execute(node, context, @graph, [])
    end

    test "skips unavailable backends" do
      node = select_node([["anthropic", "opus"], ["gemini", "auto"]])

      context =
        Context.new(%{
          "tier" => "complex",
          "avail_anthropic" => "false",
          "avail_gemini" => "true",
          "trust_anthropic" => "true",
          "trust_gemini" => "true",
          "quota_anthropic" => "true",
          "quota_gemini" => "true"
        })

      assert %Outcome{
               status: :success,
               context_updates: %{
                 "selected_backend" => "gemini",
                 "selected_model" => "auto"
               }
             } = RoutingHandler.execute(node, context, @graph, [])
    end

    test "skips untrusted backends" do
      node = select_node([["openai", "gpt5"], ["anthropic", "sonnet"]])

      context =
        Context.new(%{
          "tier" => "complex",
          "avail_openai" => "true",
          "avail_anthropic" => "true",
          "trust_openai" => "false",
          "trust_anthropic" => "true",
          "quota_openai" => "true",
          "quota_anthropic" => "true"
        })

      assert %Outcome{
               status: :success,
               context_updates: %{
                 "selected_backend" => "anthropic",
                 "selected_model" => "sonnet"
               }
             } = RoutingHandler.execute(node, context, @graph, [])
    end

    test "skips quota-exhausted backends" do
      node = select_node([["gemini", "auto"], ["anthropic", "sonnet"]])

      context =
        Context.new(%{
          "tier" => "moderate",
          "avail_gemini" => "true",
          "avail_anthropic" => "true",
          "trust_gemini" => "true",
          "trust_anthropic" => "true",
          "quota_gemini" => "false",
          "quota_anthropic" => "true"
        })

      assert %Outcome{
               status: :success,
               context_updates: %{
                 "selected_backend" => "anthropic",
                 "selected_model" => "sonnet"
               }
             } = RoutingHandler.execute(node, context, @graph, [])
    end

    test "excludes specified backends" do
      node = select_node([["anthropic", "sonnet"], ["openai", "gpt5"]])

      context =
        Context.new(%{
          "tier" => "complex",
          "exclude" => "anthropic",
          "avail_anthropic" => "true",
          "avail_openai" => "true",
          "trust_anthropic" => "true",
          "trust_openai" => "true",
          "quota_anthropic" => "true",
          "quota_openai" => "true"
        })

      assert %Outcome{
               status: :success,
               context_updates: %{
                 "selected_backend" => "openai",
                 "selected_model" => "gpt5"
               }
             } = RoutingHandler.execute(node, context, @graph, [])
    end

    test "returns fail when no candidates pass filters" do
      node = select_node([["anthropic", "opus"]])

      context =
        Context.new(%{
          "tier" => "critical",
          "avail_anthropic" => "false"
        })

      assert %Outcome{
               status: :fail,
               failure_reason: "No candidates passed filters"
             } = RoutingHandler.execute(node, context, @graph, [])
    end

    test "returns fail for empty candidates" do
      node = select_node([])

      context = Context.new(%{"tier" => "trivial"})

      assert %Outcome{status: :fail} = RoutingHandler.execute(node, context, @graph, [])
    end

    test "budget over — only free backends allowed for non-critical" do
      node = select_node([["anthropic", "sonnet"], ["ollama", "auto"]])

      context =
        Context.new(%{
          "tier" => "moderate",
          "budget_status" => "over",
          "avail_anthropic" => "true",
          "avail_ollama" => "true",
          "trust_anthropic" => "true",
          "trust_ollama" => "true",
          "quota_anthropic" => "true",
          "quota_ollama" => "true",
          "free_anthropic" => "false",
          "free_ollama" => "true"
        })

      assert %Outcome{
               status: :success,
               context_updates: %{
                 "selected_backend" => "ollama",
                 "selected_model" => "auto"
               }
             } = RoutingHandler.execute(node, context, @graph, [])
    end

    test "budget over — critical tier bypasses budget constraints" do
      node = select_node([["anthropic", "opus"]])

      context =
        Context.new(%{
          "tier" => "critical",
          "budget_status" => "over",
          "avail_anthropic" => "true",
          "trust_anthropic" => "true",
          "quota_anthropic" => "true",
          "free_anthropic" => "false"
        })

      assert %Outcome{
               status: :success,
               context_updates: %{
                 "selected_backend" => "anthropic",
                 "selected_model" => "opus"
               }
             } = RoutingHandler.execute(node, context, @graph, [])
    end

    test "budget low — free backends sorted first" do
      node = select_node([["anthropic", "sonnet"], ["ollama", "auto"]])

      context =
        Context.new(%{
          "tier" => "moderate",
          "budget_status" => "low",
          "avail_anthropic" => "true",
          "avail_ollama" => "true",
          "trust_anthropic" => "true",
          "trust_ollama" => "true",
          "quota_anthropic" => "true",
          "quota_ollama" => "true",
          "free_anthropic" => "false",
          "free_ollama" => "true"
        })

      # ollama should be sorted first because it's free
      assert %Outcome{
               status: :success,
               context_updates: %{
                 "selected_backend" => "ollama",
                 "selected_model" => "auto"
               }
             } = RoutingHandler.execute(node, context, @graph, [])
    end

    test "fallback node ID sets routing_reason to fallback" do
      node = %Node{
        id: "select_fallback",
        attrs: %{
          "type" => "routing.select",
          "candidates" => Jason.encode!([["lmstudio", "auto"]])
        }
      }

      context =
        Context.new(%{
          "tier" => "moderate",
          "avail_lmstudio" => "true",
          "trust_lmstudio" => "true",
          "quota_lmstudio" => "true"
        })

      assert %Outcome{
               status: :success,
               context_updates: %{
                 "routing_reason" => "fallback"
               }
             } = RoutingHandler.execute(node, context, @graph, [])
    end

    test "non-fallback node ID sets routing_reason to tier_match" do
      node = select_node([["anthropic", "opus"]], "select_critical")

      context =
        Context.new(%{
          "tier" => "critical",
          "avail_anthropic" => "true",
          "trust_anthropic" => "true",
          "quota_anthropic" => "true"
        })

      assert %Outcome{
               context_updates: %{"routing_reason" => "tier_match"}
             } = RoutingHandler.execute(node, context, @graph, [])
    end
  end

  describe "idempotency/0" do
    test "reports read_only" do
      assert RoutingHandler.idempotency() == :read_only
    end
  end

  # --- Helpers ---

  defp select_node(candidates, id \\ "select_test") do
    %Node{
      id: id,
      attrs: %{
        "type" => "routing.select",
        "candidates" => Jason.encode!(candidates)
      }
    }
  end
end

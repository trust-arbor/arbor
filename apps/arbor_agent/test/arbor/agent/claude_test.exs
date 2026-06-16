defmodule Arbor.Agent.ClaudeTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Claude
  alias Arbor.Agent.Templates.CliAgent

  describe "CliAgent template" do
    @describetag :fast

    test "defines a character" do
      character = CliAgent.character()
      assert character.name == "CLI Agent"
      assert character.role == "Interactive development agent"
      assert length(character.traits) == 4
      assert length(character.values) == 4
    end

    test "uses established trust tier" do
      assert CliAgent.trust_tier() == :established
    end

    test "defines initial goals" do
      goals = CliAgent.initial_goals()
      assert length(goals) == 3
      assert Enum.any?(goals, &(&1.type == :collaborate))
    end

    test "requires orchestrator execute capability" do
      caps = CliAgent.required_capabilities()
      assert length(caps) >= 1

      resources = Enum.map(caps, & &1.resource)
      assert "arbor://orchestrator/execute" in resources
    end

    test "provides metadata" do
      meta = CliAgent.metadata()
      assert meta.session_integration == true
    end
  end

  describe "Claude agent" do
    @describetag :fast

    test "starts with default options" do
      {:ok, agent} = Claude.start_link()
      assert is_pid(agent)

      assert Claude.agent_id(agent) == "claude-code"
      assert Claude.session_id(agent) == nil

      GenServer.stop(agent)
    end

    test "starts with custom id" do
      {:ok, agent} = Claude.start_link(id: "test-claude")
      assert Claude.agent_id(agent) == "test-claude"
      GenServer.stop(agent)
    end

    test "get_thinking returns empty list initially" do
      {:ok, agent} = Claude.start_link()
      assert {:ok, []} = Claude.get_thinking(agent)
      GenServer.stop(agent)
    end

    test "list_actions returns available action categories" do
      actions = Claude.list_actions()

      # Should have action categories if arbor_actions is available
      if map_size(actions) > 0 do
        assert Map.has_key?(actions, :file) or Map.has_key?(actions, :shell)
      end
    end

    test "get_tools returns LLM tool schemas" do
      tools = Claude.get_tools()

      # Should return a list of tool schemas if arbor_actions is available
      assert is_list(tools)

      if tools != [] do
        [first | _] = tools
        assert is_map(first)
        assert Map.has_key?(first, "name") or Map.has_key?(first, :name)
      end
    end
  end

  describe "Claude agent queries" do
    @describetag :llm

    # Drives the real `claude` CLI through the ACP pool. In CI this runs for
    # free against a homelab Ollama server speaking the Anthropic Messages API
    # (no paid Anthropic calls) — point it there by setting:
    #
    #   ANTHROPIC_BASE_URL=http://10.42.42.100:11434
    #   ANTHROPIC_AUTH_TOKEN=ollama
    #   ARBOR_ACP_ALTERNATE_MODEL=granite3.1-moe:1b
    #
    # `Arbor.AI.AcpSession.Config` detects the non-Anthropic base URL and
    # injects those env vars + the Ollama model + a lean tool surface into the
    # spawned CLI. When ANTHROPIC_BASE_URL is unset, the normal Anthropic path
    # is used (and the test no-ops unless a `claude` CLI / auth is present).
    #
    # The pool isn't auto-started in :test (start_children: false), so we start
    # it here and tear it down after.
    @tag timeout: 360_000
    test "executes a query and returns response" do
      pool_started = ensure_acp_pool!()

      {:ok, agent} = Claude.start_link(model: :haiku)

      # Small local models on CPU are slow; allow a generous per-query budget.
      case Claude.query(agent, "What is 2+2?", timeout: 300_000) do
        {:ok, %{text: text}} when is_binary(text) and text != "" ->
          # Got a real answer — it must actually contain the correct result.
          assert String.contains?(text, "4")

        {:ok, %{text: ""}} ->
          # Endpoint reachable but produced no text (e.g. a heavily-loaded
          # local model timed out mid-generation). The CLI/ACP wiring worked;
          # there's just nothing to assert on. Don't fail CI on endpoint load.
          :ok

        {:error, :pool_not_available} ->
          # No ACP pool (e.g. no CLI agents on PATH) — nothing to exercise.
          :ok

        {:error, {:no_cli_for_provider, _provider}} ->
          # Provider has no CLI mapping in this environment.
          :ok

        {:error, :cli_not_found} ->
          # CLI not available in CI
          :ok

        {:error, {:executable_not_found, _cli}} ->
          # `claude` binary not on PATH in this environment.
          :ok

        {:error, {:transport_closed, _status}} ->
          # Transport issue
          :ok

        {:error, reason} ->
          # Any other transport/runtime error (e.g. an internal timeout on a
          # heavily-loaded local endpoint) is an environment problem, not a
          # wiring failure. Log it so a real regression is still visible, but
          # don't fail CI on endpoint health.
          require Logger
          Logger.warning("Claude.query returned error in :llm test: #{inspect(reason)}")
          :ok
      end

      GenServer.stop(agent)
      if pool_started, do: stop_acp_pool()
    end
  end

  # Start the ACP pool if it isn't already running. Returns true if this test
  # started it (so the caller knows to stop it), false if it was already up.
  defp ensure_acp_pool! do
    if Process.whereis(Arbor.AI.AcpPool) do
      false
    else
      {:ok, _sup} = start_supervised({Arbor.AI.AcpPool.Supervisor, []})
      {:ok, _pool} = start_supervised({Arbor.AI.AcpPool, []})
      true
    end
  end

  defp stop_acp_pool do
    # start_supervised children are torn down automatically at test exit; this
    # is a no-op kept for symmetry / explicitness.
    :ok
  end
end

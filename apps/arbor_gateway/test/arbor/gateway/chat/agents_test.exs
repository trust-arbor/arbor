# Tests the `GET /api/chat/agents` listing: the capability→agents derivation
# (Arbor.Gateway.Chat.Agents) and the router endpoint that wraps it. Cross-app
# collaborators (Security.list_capabilities, Agent.Manager.find_agent,
# Agent.Lifecycle.list_agents) are faked via the same app-env seams the chat
# Socket uses. The parent auth pipeline is NOT re-tested here — the router sees
# `conn.assigns.agent_id` already set, the way the pipeline leaves it.
#
# Mirrors `mix arbor.agent list --all`: an authorized agent is listed whether it
# is RUNNING or STOPPED. agent_a runs; agent_b is stopped-but-authorized (has a
# persisted profile); agent_c is authorized but resolves to neither.

defmodule Arbor.Gateway.Chat.AgentsTest.FakeSecurity do
  # "human_3caps" holds three chat caps (one a dup) + an unrelated cap.
  def list_capabilities("human_3caps", _opts) do
    {:ok,
     [
       %{resource_uri: "arbor://chat/agent/agent_a"},
       %{resource_uri: "arbor://chat/agent/agent_b"},
       %{resource_uri: "arbor://chat/agent/agent_c"},
       %{resource_uri: "arbor://chat/agent/agent_a"},
       %{resource_uri: "arbor://fs/read/**"}
     ]}
  end

  def list_capabilities("human_none", _opts), do: {:ok, []}
  def list_capabilities(_principal, _opts), do: {:ok, []}
end

defmodule Arbor.Gateway.Chat.AgentsTest.FakeManager do
  # Only agent_a is running.
  def find_agent("agent_a"),
    do: {:ok, self(), %{display_name: "Alice", model_config: %{id: "gpt-4o"}}}

  def find_agent(_), do: :not_found
end

defmodule Arbor.Gateway.Chat.AgentsTest.FakeLifecycle do
  # Persisted profiles: agent_a (running) + agent_b (stopped) have profiles;
  # agent_c does not.
  def list_agents do
    [
      %{agent_id: "agent_a", display_name: "Alice", template: :researcher},
      %{agent_id: "agent_b", display_name: "Bob", template: :coder}
    ]
  end
end

defmodule Arbor.Gateway.Chat.AgentsTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Arbor.Gateway.Chat.Agents
  alias Arbor.Gateway.Chat.AgentsTest.{FakeLifecycle, FakeManager, FakeSecurity}
  alias Arbor.Gateway.Chat.Router

  @moduletag :fast

  @opts Router.init([])

  setup do
    Application.put_env(:arbor_gateway, :chat_security, FakeSecurity)
    Application.put_env(:arbor_gateway, :chat_agent_manager, FakeManager)
    Application.put_env(:arbor_gateway, :chat_lifecycle, FakeLifecycle)

    on_exit(fn ->
      for k <- [:chat_security, :chat_agent_manager, :chat_lifecycle] do
        Application.delete_env(:arbor_gateway, k)
      end
    end)

    :ok
  end

  describe "Agents.list_for_principal/1" do
    test "keeps only chat caps, dedups ids, and lists running + stopped + unknown" do
      agents = Agents.list_for_principal("human_3caps")

      assert length(agents) == 3
      by_id = Map.new(agents, &{&1["agent_id"], &1})

      # Running: name from registry metadata, model from model_config, template
      # from the persisted profile.
      assert by_id["agent_a"] == %{
               "agent_id" => "agent_a",
               "display_name" => "Alice",
               "template" => "researcher",
               "model" => "gpt-4o",
               "running" => true
             }

      # Stopped but authorized: resolved from the persisted profile, running:false.
      assert by_id["agent_b"] == %{
               "agent_id" => "agent_b",
               "display_name" => "Bob",
               "template" => "coder",
               "model" => "-",
               "running" => false
             }

      # Authorized but resolves to neither a live agent nor a profile: bare id.
      assert by_id["agent_c"] == %{
               "agent_id" => "agent_c",
               "display_name" => "agent_c",
               "template" => "-",
               "model" => "-",
               "running" => false
             }
    end

    test "a STOPPED authorized agent appears with running:false and its profile name" do
      agents = Agents.list_for_principal("human_3caps")
      bob = Enum.find(agents, &(&1["agent_id"] == "agent_b"))

      assert bob["running"] == false
      assert bob["display_name"] == "Bob"
      assert bob["template"] == "coder"
    end

    test "returns [] for a principal holding no chat caps" do
      assert Agents.list_for_principal("human_none") == []
    end
  end

  describe "Agents.resolve_token/2" do
    test "exact full id resolves" do
      assert {:ok, "agent_a"} = Agents.resolve_token("human_3caps", "agent_a")
    end

    test "display_name resolves case-insensitively" do
      assert {:ok, "agent_a"} = Agents.resolve_token("human_3caps", "alice")
      assert {:ok, "agent_b"} = Agents.resolve_token("human_3caps", "BOB")
    end

    test "a unique display_name prefix resolves" do
      assert {:ok, "agent_a"} = Agents.resolve_token("human_3caps", "Al")
    end

    test "an ambiguous prefix returns the candidates" do
      assert {:error, {:ambiguous, candidates}} = Agents.resolve_token("human_3caps", "agent_")
      assert Enum.map(candidates, & &1["agent_id"]) |> Enum.sort() == ~w(agent_a agent_b agent_c)
    end

    test "no match returns :not_found" do
      assert {:error, :not_found} = Agents.resolve_token("human_3caps", "zzz")
    end

    test "scoped to authorized agents — can't resolve one the principal can't chat with" do
      # agent_a exists, but human_none holds no chat cap for it.
      assert {:error, :not_found} = Agents.resolve_token("human_none", "agent_a")
    end
  end

  describe "GET /api/chat/agents" do
    test "returns N agents (running + stopped) for a principal with N chat caps" do
      conn =
        :get
        |> conn("/agents")
        |> assign(:agent_id, "human_3caps")
        |> Router.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"

      %{"agents" => agents} = Jason.decode!(conn.resp_body)
      assert length(agents) == 3

      by_id = Map.new(agents, &{&1["agent_id"], &1})
      assert by_id["agent_a"]["running"] == true
      assert by_id["agent_b"]["running"] == false
      assert by_id["agent_b"]["display_name"] == "Bob"
    end

    test "returns an empty list for a principal with no chat caps" do
      conn =
        :get
        |> conn("/agents")
        |> assign(:agent_id, "human_none")
        |> Router.call(@opts)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"agents" => []}
    end

    test "rejects when the pipeline left no authenticated principal" do
      # The parent Router pipeline rejects unauthenticated requests before this
      # sub-router; this only asserts we don't serve a listing without a principal.
      conn = :get |> conn("/agents") |> Router.call(@opts)
      assert conn.status == 401
    end
  end
end

defmodule Arbor.Gateway.Memory.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Arbor.Gateway.Memory.Router
  alias Arbor.Memory
  alias Arbor.Memory.WorkingMemory

  @moduletag :fast

  @opts Router.init([])

  # Start security infrastructure needed for M4 authorization checks
  setup_all do
    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []}
        ] do
      Supervisor.start_child(Arbor.Security.Supervisor, child)
    end

    :ok
  end

  setup do
    # Use unique agent IDs to avoid test interference
    agent_id = "gateway_memory_test_#{System.unique_integer([:positive])}"

    # Grant memory capabilities for the test agent (M4 authorization)
    # capability_signing_required: false in test config, so direct put works
    now = DateTime.utc_now()

    for action <- [:read, :write] do
      cap = %Arbor.Contracts.Security.Capability{
        id: "cap_mem_#{action}_#{agent_id}",
        principal_id: agent_id,
        resource_uri: "arbor://memory/#{action}/#{agent_id}",
        granted_at: now,
        expires_at: DateTime.add(now, 3600, :second)
      }

      Arbor.Security.CapabilityStore.put(cap)
    end

    on_exit(fn -> Memory.cleanup_for_agent(agent_id) end)
    {:ok, agent_id: agent_id}
  end

  describe "POST /recall" do
    test "returns results for initialized agent", %{agent_id: agent_id} do
      # Initialize agent memory and index some content
      {:ok, _pid} = Memory.init_for_agent(agent_id)
      {:ok, _entry_id} = Memory.index(agent_id, "The sky is blue", %{type: :fact})

      body = %{agent_id: agent_id, query: "sky color"}

      conn =
        conn(:post, "/recall", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
      assert is_list(response["results"])
    end

    test "returns 404 for uninitialized agent", %{agent_id: agent_id} do
      body = %{agent_id: agent_id, query: "test query"}

      conn =
        conn(:post, "/recall", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 404
      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "error"
      assert response["reason"] =~ "not initialized"
    end

    test "returns 400 if agent_id or query missing" do
      body = %{agent_id: "test"}

      conn =
        conn(:post, "/recall", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "error"
    end
  end

  describe "POST /index" do
    test "stores content for initialized agent", %{agent_id: agent_id} do
      {:ok, _pid} = Memory.init_for_agent(agent_id)

      body = %{
        agent_id: agent_id,
        content: "Important fact to remember",
        metadata: %{type: "fact", source: "user"}
      }

      conn =
        conn(:post, "/index", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
      assert is_binary(response["entry_id"])
    end

    test "returns 404 for uninitialized agent", %{agent_id: agent_id} do
      body = %{agent_id: agent_id, content: "test content"}

      conn =
        conn(:post, "/index", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 404
    end

    test "returns 400 if required fields missing" do
      body = %{agent_id: "test"}

      conn =
        conn(:post, "/index", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
    end
  end

  describe "GET /working/:agent_id" do
    test "returns working memory if exists", %{agent_id: agent_id} do
      # Create and save working memory
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("Test thought")
        |> WorkingMemory.set_goals(["Test goal"])

      Memory.save_working_memory(agent_id, wm)

      conn =
        conn(:get, "/working/#{agent_id}")
        |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
      assert response["working_memory"]["agent_id"] == agent_id
      thoughts = response["working_memory"]["recent_thoughts"]
      assert is_list(thoughts) and length(thoughts) == 1
      assert hd(thoughts)["content"] == "Test thought"
      goals = response["working_memory"]["active_goals"]
      assert is_list(goals) and length(goals) == 1
      assert hd(goals)["description"] == "Test goal"
    end

    test "returns 404 if no working memory exists", %{agent_id: agent_id} do
      conn =
        conn(:get, "/working/#{agent_id}")
        |> Router.call(@opts)

      assert conn.status == 404
      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "error"
    end
  end

  describe "PUT /working/:agent_id" do
    test "saves working memory", %{agent_id: agent_id} do
      body = %{
        working_memory: %{
          recent_thoughts: ["New thought"],
          active_goals: ["New goal"],
          engagement_level: 0.7
        }
      }

      conn =
        conn(:put, "/working/#{agent_id}", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"

      # Verify it was saved
      loaded = Memory.get_working_memory(agent_id)
      assert loaded.agent_id == agent_id
      assert length(loaded.recent_thoughts) == 1
      assert hd(loaded.recent_thoughts).content == "New thought"
      assert length(loaded.active_goals) == 1
      assert hd(loaded.active_goals).description == "New goal"
      assert loaded.engagement_level == 0.7
    end

    test "returns 400 if working_memory missing" do
      conn =
        conn(:put, "/working/test_agent", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
    end
  end

  describe "POST /summarize" do
    test "returns fallback summary when LLM unavailable", %{agent_id: agent_id} do
      body = %{
        agent_id: agent_id,
        text:
          "This is a long text that needs to be summarized. " <>
            "It contains many important details that should be captured."
      }

      conn =
        conn(:post, "/summarize", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      # Summarizer falls back to extractive summary when LLM unavailable
      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
      assert is_binary(response["summary"])
    end

    test "returns 400 if required fields missing" do
      body = %{agent_id: "test"}

      conn =
        conn(:post, "/summarize", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
    end
  end

  describe "unknown routes" do
    test "returns 404" do
      conn =
        conn(:get, "/unknown")
        |> Router.call(@opts)

      assert conn.status == 404
    end
  end
end

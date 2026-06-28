# Tests the agent-lifecycle endpoints (POST /api/chat/agents,
# /agents/:id/start, /agents/:id/stop) and the Arbor.Gateway.Chat.Lifecycle
# module behind them. Cross-app collaborators (Arbor.Agent authorize_* gates,
# Agent.Lifecycle.start, TemplateStore.get, LLMDefaults) are faked via the same
# app-env seams the chat Socket + Chat.Agents use. The parent auth pipeline is
# NOT re-tested — the router sees `conn.assigns.agent_id` already set.
#
# The fakes record their inputs to the test pid so we can assert the create flow
# passes `principal_id` (the chat-grant) and the right template/model_config.

defmodule Arbor.Gateway.Chat.LifecycleTest.FakeAgent do
  # authorize_create/3 — gates on the GENERIC create cap, then "creates".
  # "human_ok" is authorized; anyone else is denied.
  def authorize_create("human_ok", display_name, opts) do
    send(self_pid(), {:authorize_create, display_name, opts})
    {:ok, %{agent_id: "agent_new123", display_name: display_name}}
  end

  def authorize_create(_principal, _display_name, _opts),
    do: {:error, {:unauthorized, :no_capability}}

  # authorize_restore/3 — gate for /start. "human_ok" authorized. The arity-3
  # form mirrors the real Arbor.Agent facade, which takes `opts` (the gateway
  # forwards the verified `:signed_request` there); we capture opts so a test can
  # assert the threading.
  def authorize_restore("human_ok", id, opts) do
    send(self_pid(), {:authorize_restore, id, opts})
    {:ok, %{agent_id: id}}
  end

  def authorize_restore("human_missing", _id, _opts), do: {:error, :not_found}
  def authorize_restore(_principal, _id, _opts), do: {:error, {:unauthorized, :no_capability}}

  # authorize_stop/3 — gate + stop for /stop (arity-3 mirrors the real facade).
  def authorize_stop("human_ok", id, opts) do
    send(self_pid(), {:authorize_stop, id, opts})
    :ok
  end

  def authorize_stop("human_missing", _id, _opts), do: {:error, :not_found}
  def authorize_stop(_principal, _id, _opts), do: {:error, {:unauthorized, :no_capability}}

  # Stash the test pid in the app env so the fake (running in the router's
  # process, which here is the test process via Plug.Test) can message it.
  defp self_pid, do: Application.get_env(:arbor_gateway, :lifecycle_test_pid, self())
end

defmodule Arbor.Gateway.Chat.LifecycleTest.FakeLifecycle do
  # Lifecycle.start/2 — records principal_id, returns a fake pid.
  def start(agent_id, opts) do
    send(test_pid(), {:lifecycle_start, agent_id, opts})

    case agent_id do
      "agent_unstartable" -> {:error, :boom}
      _ -> {:ok, self()}
    end
  end

  defp test_pid, do: Application.get_env(:arbor_gateway, :lifecycle_test_pid, self())
end

defmodule Arbor.Gateway.Chat.LifecycleTest.FakeTemplateStore do
  def get("researcher"),
    do: {:ok, %{"name" => "researcher", "character" => %{"name" => "Rita"}}}

  def get("noname"), do: {:ok, %{"name" => "noname"}}
  def get(_), do: {:error, :not_found}
end

defmodule Arbor.Gateway.Chat.LifecycleTest.FakeLLMDefaults do
  def default_model(_opts \\ []), do: "default/model-x"
  def default_provider(_opts \\ []), do: :openrouter
end

defmodule Arbor.Gateway.Chat.LifecycleTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Arbor.Gateway.Chat.Lifecycle
  alias Arbor.Gateway.Chat.Router

  alias Arbor.Gateway.Chat.LifecycleTest.{
    FakeAgent,
    FakeLifecycle,
    FakeLLMDefaults,
    FakeTemplateStore
  }

  @moduletag :fast

  @opts Router.init([])

  # Stand-in for the SignedRequest the gateway pipeline verifies upstream; the
  # endpoints must forward exactly this into the capability check's opts.
  @sentinel_signed_request :sentinel_verified_signed_request

  setup do
    Application.put_env(:arbor_gateway, :chat_agent_facade, FakeAgent)
    Application.put_env(:arbor_gateway, :chat_lifecycle, FakeLifecycle)
    Application.put_env(:arbor_gateway, :chat_template_store, FakeTemplateStore)
    Application.put_env(:arbor_gateway, :chat_llm_defaults, FakeLLMDefaults)
    Application.put_env(:arbor_gateway, :lifecycle_test_pid, self())

    on_exit(fn ->
      for k <- [
            :chat_agent_facade,
            :chat_lifecycle,
            :chat_template_store,
            :chat_llm_defaults,
            :lifecycle_test_pid
          ] do
        Application.delete_env(:arbor_gateway, k)
      end
    end)

    :ok
  end

  # POST a JSON body with the principal already in assigns (as the parent
  # pipeline leaves it) and the body already parsed (as :conditional_parsers
  # leaves it).
  defp post_json(path, principal, body) do
    :post
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Map.put(:body_params, body)
    |> assign(:agent_id, principal)
    # The parent pipeline's SignedRequestAuth stashes the verified SignedRequest
    # here; the lifecycle endpoints must forward it to the cap check. We use a
    # sentinel so tests can assert the threading end-to-end.
    |> assign(:signed_request, @sentinel_signed_request)
    |> Router.call(@opts)
  end

  describe "Lifecycle.create/3 (unit)" do
    test "authorized: gates, creates with principal_id chat-grant + model_config, then starts" do
      assert {:ok, result} =
               Lifecycle.create("human_ok", %{"template" => "researcher", "name" => "Custom"})

      assert result == %{
               "agent_id" => "agent_new123",
               "display_name" => "Custom",
               "running" => true
             }

      # The create gate received the full opts including principal_id (chat-grant)
      # and a model_config built from the default model.
      assert_received {:authorize_create, "Custom", opts}
      assert opts[:principal_id] == "human_ok"
      assert opts[:template] == "researcher"
      assert opts[:display_name] == "Custom"
      assert opts[:model_config][:id] == "default/model-x"

      # And then the agent was started with the principal_id too.
      assert_received {:lifecycle_start, "agent_new123", start_opts}
      assert start_opts[:principal_id] == "human_ok"
    end

    test "defaults display_name from the template character name" do
      assert {:ok, %{"display_name" => "Rita"}} =
               Lifecycle.create("human_ok", %{"template" => "researcher"})
    end

    test "honors a model override" do
      assert {:ok, _} =
               Lifecycle.create("human_ok", %{"template" => "researcher", "model" => "gpt-4o"})

      assert_received {:authorize_create, _name, opts}
      assert opts[:model_config][:id] == "gpt-4o"
    end

    test "unauthorized principal → 403 without creating" do
      assert {:error, 403, _msg} =
               Lifecycle.create("intruder", %{"template" => "researcher"})

      refute_received {:authorize_create, _, _}
      refute_received {:lifecycle_start, _, _}
    end

    test "missing template → 422" do
      assert {:error, 422, msg} = Lifecycle.create("human_ok", %{})
      assert msg =~ "template"
    end

    test "unknown template → 404" do
      assert {:error, 404, msg} = Lifecycle.create("human_ok", %{"template" => "nope"})
      assert msg =~ "template not found"
    end
  end

  describe "POST /api/chat/agents" do
    test "authorized create+start → 200 with the new agent" do
      conn = post_json("/agents", "human_ok", %{"template" => "researcher", "name" => "Custom"})

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["agent_id"] == "agent_new123"
      assert body["running"] == true
    end

    test "unauthorized principal → 403" do
      conn = post_json("/agents", "intruder", %{"template" => "researcher"})
      assert conn.status == 403
    end

    test "missing template → 422" do
      conn = post_json("/agents", "human_ok", %{})
      assert conn.status == 422
    end

    test "unknown template → 404" do
      conn = post_json("/agents", "human_ok", %{"template" => "nope"})
      assert conn.status == 404
    end

    test "rejects when the pipeline left no authenticated principal" do
      conn =
        :post
        |> conn("/agents", Jason.encode!(%{"template" => "researcher"}))
        |> Map.put(:body_params, %{"template" => "researcher"})
        |> Router.call(@opts)

      assert conn.status == 401
    end
  end

  describe "POST /api/chat/agents/:id/start" do
    test "authorized → 200 and starts with principal_id" do
      conn = post_json("/agents/agent_existing/start", "human_ok", %{})

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["agent_id"] == "agent_existing"
      assert_received {:authorize_restore, "agent_existing", auth_opts}
      # The gateway forwards the pipeline-verified signed_request into the cap check.
      assert auth_opts[:signed_request] == @sentinel_signed_request
      assert_received {:lifecycle_start, "agent_existing", opts}
      assert opts[:principal_id] == "human_ok"
    end

    test "unauthorized → 403" do
      conn = post_json("/agents/agent_existing/start", "intruder", %{})
      assert conn.status == 403
    end

    test "restore gate reports not found → 404" do
      conn = post_json("/agents/agent_gone/start", "human_missing", %{})
      assert conn.status == 404
    end

    test "lifecycle start failure → 409" do
      conn = post_json("/agents/agent_unstartable/start", "human_ok", %{})
      assert conn.status == 409
    end
  end

  describe "POST /api/chat/agents/:id/stop" do
    test "authorized → 200 and stops" do
      conn = post_json("/agents/agent_running/stop", "human_ok", %{})

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["agent_id"] == "agent_running"
      assert body["running"] == false
      assert_received {:authorize_stop, "agent_running", auth_opts}
      # The gateway forwards the pipeline-verified signed_request into the cap check.
      assert auth_opts[:signed_request] == @sentinel_signed_request
    end

    test "unauthorized → 403" do
      conn = post_json("/agents/agent_running/stop", "intruder", %{})
      assert conn.status == 403
    end

    test "not running → 404" do
      conn = post_json("/agents/agent_gone/stop", "human_missing", %{})
      assert conn.status == 404
    end
  end
end

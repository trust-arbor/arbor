defmodule Arbor.AI.LLM.Adapter.AcpTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.AcpPool
  alias Arbor.AI.LLM.Adapter.Acp
  alias Arbor.LLM.Message
  alias Arbor.LLM.Request
  @moduletag :fast

  defmodule TimeoutClient do
    @moduledoc false

    def start_link(opts), do: Agent.start_link(fn -> opts end)

    def new_session(_client, _cwd, _opts),
      do: {:ok, %{"sessionId" => "adapter-timeout-session"}}

    def load_session(_client, session_id, _cwd, _opts),
      do: {:ok, %{"sessionId" => session_id}}

    # Honor the new ACP model-confirmation contract: return a configOptions
    # envelope echoing the requested model so create_session's
    # select_and_confirm_model/4 verification succeeds. The test exercises a
    # prompt-level timeout, not a model-selection failure.
    def set_config_option(_client, _session_id, "model", value),
      do: {:ok, %{"configOptions" => [%{"id" => "model", "currentValue" => value}]}}

    def set_config_option(_client, _session_id, _key, _value), do: :ok

    def prompt(client, _session_id, _content, _opts) do
      send(Agent.get(client, & &1)[:test_pid], {:adapter_prompt, self()})
      {:error, :timeout}
    end

    def cancel(_client, _session_id), do: :ok

    def disconnect(client) do
      test_pid = Agent.get(client, & &1)[:test_pid]
      send(test_pid, {:adapter_disconnect, client})
      Agent.stop(client, :normal)
    end
  end

  describe "provider/0" do
    test "returns acp" do
      assert Acp.provider() == "acp"
    end
  end

  describe "available?/0" do
    test "returns false when pool is not running" do
      # In test env, AcpPool is not started by default
      refute Acp.available?()
    end
  end

  describe "resolve_agent (via complete)" do
    # We can't fully test complete without a running pool, but we can test
    # the error path which confirms agent resolution ran.

    test "returns pool_not_available when pool isn't running" do
      request = %Request{
        provider: "acp",
        model: "sonnet",
        messages: [Message.new(:user, "hello")],
        provider_options: %{"agent" => "claude"}
      }

      assert {:error, :pool_not_available} = Acp.complete(request)
    end

    test "works with atom agent key" do
      request = %Request{
        provider: "acp",
        model: "sonnet",
        messages: [Message.new(:user, "hello")],
        provider_options: %{agent: :gemini}
      }

      assert {:error, :pool_not_available} = Acp.complete(request)
    end

    test "defaults agent when provider_options is empty" do
      request = %Request{
        provider: "acp",
        model: "sonnet",
        messages: [Message.new(:user, "hello")],
        provider_options: %{}
      }

      assert {:error, :pool_not_available} = Acp.complete(request)
    end

    test "defaults agent when provider_options is nil" do
      request = %Request{
        provider: "acp",
        model: "sonnet",
        messages: [Message.new(:user, "hello")]
      }

      assert {:error, :pool_not_available} = Acp.complete(request)
    end
  end

  describe "runtime_contract/0" do
    test "returns a valid contract" do
      contract = Acp.runtime_contract()
      assert contract.provider == "acp"
      assert contract.display_name == "ACP (CLI Agents)"
      assert contract.type == :cli
    end
  end

  describe "available_agents/0" do
    test "returns a list" do
      agents = Acp.available_agents()
      assert is_list(agents)
    end
  end

  test "security regression: adapter removes a recovery session instead of checking it in" do
    original_client = Application.get_env(:arbor_ai, :acp_client_module)
    Application.put_env(:arbor_ai, :acp_client_module, TimeoutClient)

    on_exit(fn ->
      if original_client,
        do: Application.put_env(:arbor_ai, :acp_client_module, original_client),
        else: Application.delete_env(:arbor_ai, :acp_client_module)
    end)

    start_supervised!(Arbor.AI.AcpPool.Supervisor)
    start_supervised!({AcpPool, default_max: 1, cleanup_interval_ms: 100_000})

    request = %Request{
      provider: "acp",
      model: "test",
      messages: [Message.new(:user, "timeout")],
      provider_options: %{agent: :test}
    }

    assert {:error, :timeout} =
             Acp.complete(request, client_opts: [test_pid: self()], timeout: 200)

    assert_receive {:adapter_prompt, _worker}
    assert AcpPool.sessions() == []
    assert_receive {:adapter_disconnect, _client}, 1_000
  end

  describe "normalize_usage/1" do
    test "handles snake_case string keys (native ACP)" do
      usage = %{"input_tokens" => 100, "output_tokens" => 50}
      result = Acp.normalize_usage(usage)
      assert result.prompt_tokens == 100
      assert result.completion_tokens == 50
      assert result.total_tokens == 150
    end

    test "handles camelCase string keys (Claude/Codex adapter format)" do
      usage = %{"inputTokens" => 200, "outputTokens" => 75}
      result = Acp.normalize_usage(usage)
      assert result.prompt_tokens == 200
      assert result.completion_tokens == 75
      assert result.total_tokens == 275
    end

    test "handles atom keys" do
      usage = %{input_tokens: 30, output_tokens: 20}
      result = Acp.normalize_usage(usage)
      assert result.prompt_tokens == 30
      assert result.completion_tokens == 20
      assert result.total_tokens == 50
    end

    test "uses explicit total_tokens when provided" do
      usage = %{"input_tokens" => 100, "output_tokens" => 50, "total_tokens" => 999}
      result = Acp.normalize_usage(usage)
      assert result.total_tokens == 999
    end

    test "returns zeros for empty map" do
      result = Acp.normalize_usage(%{})
      assert result == %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
    end

    test "returns zeros for non-map" do
      result = Acp.normalize_usage(nil)
      assert result == %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
    end
  end
end

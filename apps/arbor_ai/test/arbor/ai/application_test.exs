defmodule Arbor.AI.ApplicationTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.AI.AcpSession.Config

  setup do
    previous_pool = Application.fetch_env(:arbor_ai, :enable_acp_pool)
    previous_providers = Application.fetch_env(:arbor_ai, :acp_providers)

    on_exit(fn ->
      restore_env(:enable_acp_pool, previous_pool)
      restore_env(:acp_providers, previous_providers)
    end)

    :ok
  end

  test "propagates the Arbor coding-plan key alias to ReqLLM" do
    env_key = "ZAI_CODING_PLAN_API_KEY"
    config_key = :zai_coding_plan_api_key
    previous_env = System.get_env(env_key)
    previous_config = Application.fetch_env(:req_llm, config_key)

    on_exit(fn ->
      if previous_env, do: System.put_env(env_key, previous_env), else: System.delete_env(env_key)

      case previous_config do
        {:ok, value} -> Application.put_env(:req_llm, config_key, value)
        :error -> Application.delete_env(:req_llm, config_key)
      end
    end)

    System.put_env(env_key, "test-coding-plan-key")
    Application.delete_env(:req_llm, config_key)

    Arbor.AI.Application.propagate_api_keys()

    assert ReqLLM.get_key(config_key) == "test-coding-plan-key"
  end

  describe "acp pool catalog discovery" do
    test "auto-enables when Grok is the only installed catalog CLI" do
      Application.delete_env(:arbor_ai, :enable_acp_pool)

      assert {:grok, :native} in Config.list_providers()
      assert {:ok, grok_opts} = Config.resolve(:grok)
      [executable | _args] = Keyword.fetch!(grok_opts, :command)

      refute executable in ~w(claude gemini codex goose aider opencode cline),
             "Grok must not depend on the retired hardcoded CLI list"

      assert_pool_started(executable_checker: only([executable]))
    end

    test "does not auto-enable when no catalog CLI is installed" do
      Application.delete_env(:arbor_ai, :enable_acp_pool)

      refute_pool_started(executable_checker: only([]))
    end

    test "explicit enable_acp_pool false wins over an installed CLI" do
      Application.put_env(:arbor_ai, :enable_acp_pool, false)

      refute_pool_started(executable_checker: only(["grok", "claude", "codex"]))
    end

    test "explicit enable_acp_pool true starts the pool with no installed CLI" do
      Application.put_env(:arbor_ai, :enable_acp_pool, true)

      assert_pool_started(executable_checker: only([]))
    end

    test "auto-enables from a configured native executable override" do
      Application.delete_env(:arbor_ai, :enable_acp_pool)

      override_path = "/opt/arbor-test/gemini-override"
      prior = Application.get_env(:arbor_ai, :acp_providers, %{})

      Application.put_env(
        :arbor_ai,
        :acp_providers,
        Map.put(prior, :gemini, %{command: [override_path, "--experimental-acp"]})
      )

      assert {:ok, resolved} = Config.resolve(:gemini)
      assert Keyword.fetch!(resolved, :command) == [override_path, "--experimental-acp"]

      refute_pool_started(executable_checker: only(["gemini"]))
      assert_pool_started(executable_checker: only([override_path]))
    end

    test "auto-enables when an adapted catalog CLI is the only installed executable" do
      Application.delete_env(:arbor_ai, :enable_acp_pool)

      assert {:claude, :adapted} in Config.list_providers()
      assert {:ok, claude_opts} = Config.resolve(:claude)
      refute Keyword.has_key?(claude_opts, :command)

      assert_pool_started(executable_checker: only(["claude"]))
    end
  end

  defp assert_pool_started(opts) do
    modules = pool_child_modules(opts)
    assert Arbor.AI.AcpPool.Supervisor in modules
    assert Arbor.AI.AcpPool in modules
  end

  defp refute_pool_started(opts) do
    assert pool_child_modules(opts) == []
  end

  defp pool_child_modules(opts) do
    opts
    |> Arbor.AI.Application.acp_pool_children()
    |> Enum.map(fn
      {module, _config} when is_atom(module) -> module
      module when is_atom(module) -> module
    end)
  end

  defp only(names) when is_list(names) do
    allowed = MapSet.new(names)

    fn name ->
      if MapSet.member?(allowed, name), do: "/injected/#{name}", else: nil
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:arbor_ai, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:arbor_ai, key)
end

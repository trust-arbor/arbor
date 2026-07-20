defmodule Arbor.AI.AcpSessionNativeEnvTest do
  # async: false — these tests mutate the shared `:arbor_ai, :acp_providers`
  # application env (and an OS env var) to register a temporary native provider,
  # so they must not run concurrently with the async config tests.
  use ExUnit.Case, async: false

  alias Arbor.AI.AcpSession.Config

  @moduletag :fast

  # A temporary native provider exercising static-config env + args. {:system, VAR}
  # values are resolved from the OS env at spawn; literals pass through; unset refs
  # are dropped (and logged). Kept distinct from the real :cursor provider.
  setup do
    prior = Application.fetch_env(:arbor_ai, :acp_providers)

    base_providers =
      case prior do
        {:ok, providers} -> providers
        :error -> %{}
      end

    System.put_env("ARBOR_TEST_ACP_KEY", "secret-123")

    Application.put_env(
      :arbor_ai,
      :acp_providers,
      Map.put(base_providers, :test_native_env, %{
        command: ["fake-agent", "acp"],
        args: ["--model", "anthropic/claude-4-sonnet"],
        env: [
          {"AGENT_API_KEY", {:system, "ARBOR_TEST_ACP_KEY"}},
          {"AGENT_LITERAL", "literal-val"},
          {"AGENT_MISSING", {:system, "ARBOR_TEST_UNSET_VAR_XYZ"}}
        ]
      })
    )

    on_exit(fn ->
      case prior do
        :error -> Application.delete_env(:arbor_ai, :acp_providers)
        {:ok, providers} -> Application.put_env(:arbor_ai, :acp_providers, providers)
      end

      System.delete_env("ARBOR_TEST_ACP_KEY")
    end)

    :ok
  end

  describe "native static-config args" do
    test "appends configured args to the spawned command list" do
      assert {:ok, opts} = Config.resolve(:test_native_env, [])

      assert Keyword.get(opts, :command) ==
               ["fake-agent", "acp", "--model", "anthropic/claude-4-sonnet"]
    end
  end

  describe "native static-config env" do
    test "resolves {:system, VAR} refs, passes literals, drops unset refs" do
      assert {:ok, opts} = Config.resolve(:test_native_env, [])
      env = Keyword.get(opts, :env)

      # {:system, VAR} resolved from the OS env, not the literal tuple
      assert {"AGENT_API_KEY", "secret-123"} in env
      # literal string passes through
      assert {"AGENT_LITERAL", "literal-val"} in env
      # unset ref is dropped entirely — never spawned with a missing/empty key
      refute Enum.any?(env, fn {k, _v} -> k == "AGENT_MISSING" end)
    end

    test "env keys/values reach the top level where the stdio transport reads them" do
      # ExMCP.Transport.Stdio reads top-level :command/:cd/:env, and
      # ExMCP.ACP.Client forwards all non-client keys through — so :env at the
      # top of the resolved opts is the wire, not a no-op.
      assert {:ok, opts} = Config.resolve(:test_native_env, [])
      assert is_list(Keyword.get(opts, :env))
      refute Keyword.has_key?(opts, :adapter)
    end
  end

  describe "providers without env/args are unaffected" do
    test "a bare native command resolves to just the command" do
      assert {:ok, opts} = Config.resolve(:gemini, [])
      assert Keyword.get(opts, :command) == ["gemini", "--experimental-acp"]
      refute Keyword.has_key?(opts, :env)
    end
  end

  # Exact launch argv + static Git env required after the r5 coding-benchmark
  # isolation failure (native Grok read the live Arbor repo outside its lease).
  @grok_strict_command [
    "grok",
    "--sandbox",
    "strict",
    "--no-memory",
    "--no-subagents",
    "--disable-web-search",
    "--deny",
    "MCPTool(*)",
    "--deny",
    "Bash(*)",
    "agent",
    "--no-leader",
    "--model",
    "grok-4.5",
    "stdio"
  ]

  @grok_strict_git_env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"},
    {"GIT_OPTIONAL_LOCKS", "0"},
    {"GIT_CONFIG_COUNT", "1"},
    {"GIT_CONFIG_KEY_0", "core.excludesFile"},
    {"GIT_CONFIG_VALUE_0", "/dev/null"}
  ]

  describe "security regression: Grok strict sandbox launch" do
    test "umbrella config leaves the security-sensitive Grok command to the hardened default" do
      providers = Application.get_env(:arbor_ai, :acp_providers, %{})
      refute Map.has_key?(providers, :grok)

      assert {:ok, opts} = Config.resolve(:grok, [])

      assert Keyword.get(opts, :command) == @grok_strict_command
      assert Keyword.get(opts, :env) == @grok_strict_git_env
      # Static-config-only: per-launch env injection must remain blocked.
      assert {:ok, launch_opts} =
               Config.resolve(:grok, env: [{"HOSTILE", "1"}], args: ["--escape"])

      assert Keyword.get(launch_opts, :command) == @grok_strict_command
      assert Keyword.get(launch_opts, :env) == @grok_strict_git_env
      refute Enum.any?(Keyword.get(launch_opts, :env), fn {k, _} -> k == "HOSTILE" end)
    end

    test "built-in fallback uses the same strict sandbox command and Git env" do
      providers = Application.get_env(:arbor_ai, :acp_providers, %{})
      Application.put_env(:arbor_ai, :acp_providers, Map.delete(providers, :grok))

      assert {:ok, opts} = Config.resolve(:grok, [])

      assert Keyword.get(opts, :command) == @grok_strict_command
      assert Keyword.get(opts, :env) == @grok_strict_git_env
    end
  end
end

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
    prior = Application.get_env(:arbor_ai, :acp_providers, %{})
    System.put_env("ARBOR_TEST_ACP_KEY", "secret-123")

    Application.put_env(
      :arbor_ai,
      :acp_providers,
      Map.put(prior, :test_native_env, %{
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
      Application.put_env(:arbor_ai, :acp_providers, prior)
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

  describe "configured Grok provider" do
    test "pins grok-4.5 before the stdio subcommand" do
      assert {:ok, opts} = Config.resolve(:grok, [])

      assert Keyword.get(opts, :command) ==
               ["grok", "agent", "--model", "grok-4.5", "stdio"]
    end

    test "built-in fallback also pins grok-4.5" do
      providers = Application.get_env(:arbor_ai, :acp_providers, %{})
      Application.put_env(:arbor_ai, :acp_providers, Map.delete(providers, :grok))

      assert {:ok, opts} = Config.resolve(:grok, [])

      assert Keyword.get(opts, :command) ==
               ["grok", "agent", "--model", "grok-4.5", "stdio"]
    end
  end
end

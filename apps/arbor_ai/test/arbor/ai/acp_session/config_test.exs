defmodule Arbor.AI.AcpSession.ConfigTest do
  # Mutates process-global OS env (System.put_env) — must not run async.
  use ExUnit.Case, async: false

  alias Arbor.AI.AcpSession.Config

  @env_vars ~w(ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ARBOR_ACP_ALTERNATE_MODEL)

  setup do
    prior_providers = Application.fetch_env(:arbor_ai, :acp_providers)

    stripped_providers =
      case prior_providers do
        {:ok, providers} -> Map.delete(providers, :grok)
        :error -> %{}
      end

    saved = Enum.map(@env_vars, fn v -> {v, System.get_env(v)} end)

    Application.put_env(:arbor_ai, :acp_providers, stripped_providers)

    on_exit(fn ->
      case prior_providers do
        :error -> Application.delete_env(:arbor_ai, :acp_providers)
        {:ok, providers} -> Application.put_env(:arbor_ai, :acp_providers, providers)
      end

      Enum.each(saved, fn
        {v, nil} -> System.delete_env(v)
        {v, val} -> System.put_env(v, val)
      end)
    end)

    Enum.each(@env_vars, &System.delete_env/1)
    :ok
  end

  describe "resolve/2 for :claude (default Anthropic path)" do
    @describetag :fast

    test "does NOT inject alternate-endpoint env when ANTHROPIC_BASE_URL is unset" do
      {:ok, opts} = Config.resolve(:claude, [])
      adapter_opts = Keyword.fetch!(opts, :adapter_opts)

      refute Keyword.has_key?(adapter_opts, :env)
      # Default Anthropic model is preserved, not overridden to an Ollama name.
      refute Keyword.get(adapter_opts, :model) == "granite3.1-moe:1b"
    end

    test "does NOT inject when base URL points at api.anthropic.com" do
      System.put_env("ANTHROPIC_BASE_URL", "https://api.anthropic.com")
      System.put_env("ANTHROPIC_AUTH_TOKEN", "sk-ant-xxx")

      {:ok, opts} = Config.resolve(:claude, [])
      adapter_opts = Keyword.fetch!(opts, :adapter_opts)

      refute Keyword.has_key?(adapter_opts, :env)
    end
  end

  describe "resolve/2 for :grok command hardening" do
    @describetag :fast

    test "uses immutable strict sandbox shape with explicit execute disallow" do
      assert {:ok, opts} = Config.resolve(:grok, [])

      command = Keyword.fetch!(opts, :command)

      assert command == [
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
               "--disallowed-tools",
               "execute",
               "agent",
               "--no-leader",
               "--model",
               "grok-4.5",
               "stdio"
             ]

      assert Enum.at(command, 8) == "--deny"
      assert Enum.at(command, 9) == "Bash(*)"
      assert Enum.at(command, 10) == "--disallowed-tools"
      assert Enum.at(command, 11) == "execute"
      assert Enum.at(command, 12) == "agent"
    end

    test "rejects app-level :grok overrides that remove execute disallow" do
      prior = Application.get_env(:arbor_ai, :acp_providers)

      Application.put_env(
        :arbor_ai,
        :acp_providers,
        Map.put(prior, :grok, %{
          command: [
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
          ],
          env: [
            {"GIT_CONFIG_GLOBAL", "/dev/null"},
            {"GIT_CONFIG_SYSTEM", "/dev/null"},
            {"GIT_OPTIONAL_LOCKS", "0"},
            {"GIT_CONFIG_COUNT", "1"},
            {"GIT_CONFIG_KEY_0", "core.excludesFile"},
            {"GIT_CONFIG_VALUE_0", "/dev/null"}
          ]
        })
      )

      assert {:error, :invalid_grok_command} = Config.resolve(:grok, [])
    end
  end

  describe "resolve/2 for :claude (alternate endpoint, e.g. Ollama)" do
    @describetag :fast

    setup do
      System.put_env("ANTHROPIC_BASE_URL", "http://10.42.42.100:11434")
      System.put_env("ANTHROPIC_AUTH_TOKEN", "ollama")
      System.put_env("ARBOR_ACP_ALTERNATE_MODEL", "granite3.1-moe:1b")
      :ok
    end

    test "injects ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN into the spawned CLI env" do
      {:ok, opts} = Config.resolve(:claude, [])
      env = opts |> Keyword.fetch!(:adapter_opts) |> Keyword.fetch!(:env)

      assert {"ANTHROPIC_BASE_URL", "http://10.42.42.100:11434"} in env
      assert {"ANTHROPIC_AUTH_TOKEN", "ollama"} in env
    end

    test "uses the alternate (Ollama) model for the --model flag, not a Claude id" do
      {:ok, opts} = Config.resolve(:claude, [])
      adapter_opts = Keyword.fetch!(opts, :adapter_opts)

      assert Keyword.get(adapter_opts, :model) == "granite3.1-moe:1b"
      refute Keyword.get(adapter_opts, :model) =~ "claude"
    end

    test "trims the tool surface and local settings for slow local models" do
      {:ok, opts} = Config.resolve(:claude, [])
      adapter_opts = Keyword.fetch!(opts, :adapter_opts)

      assert Keyword.get(adapter_opts, :tools) == ""
      assert Keyword.get(adapter_opts, :extra_args) == ["--setting-sources", ""]
    end

    test "a per-call Claude model id (from the pool) does not win over the Ollama model" do
      # The pool forwards request.model (a Claude id) as top-level :model.
      # The alternate-endpoint injection must override it so the CLI's
      # --model flag is the Ollama model the endpoint actually serves.
      {:ok, opts} = Config.resolve(:claude, model: "claude-haiku-4-5-20251001")
      adapter_opts = Keyword.fetch!(opts, :adapter_opts)

      assert Keyword.get(adapter_opts, :model) == "granite3.1-moe:1b"
      assert Keyword.get(opts, :model) == "granite3.1-moe:1b"
    end

    test "falls back to a default auth token when ANTHROPIC_AUTH_TOKEN is unset" do
      System.delete_env("ANTHROPIC_AUTH_TOKEN")

      {:ok, opts} = Config.resolve(:claude, [])
      env = opts |> Keyword.fetch!(:adapter_opts) |> Keyword.fetch!(:env)

      assert {"ANTHROPIC_AUTH_TOKEN", "alternate"} in env
    end
  end
end

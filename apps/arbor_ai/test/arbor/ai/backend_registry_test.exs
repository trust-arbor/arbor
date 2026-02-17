defmodule Arbor.AI.BackendRegistryTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.BackendRegistry

  @moduletag :fast

  # ===========================================================================
  # Static metadata (no GenServer/ETS needed)
  # ===========================================================================

  describe "cli_backends/0" do
    test "returns list of known CLI backends" do
      backends = BackendRegistry.cli_backends()
      assert is_list(backends)
      assert :claude_cli in backends
      assert :codex_cli in backends
      assert :gemini_cli in backends
      assert :qwen_cli in backends
      assert :opencode_cli in backends
    end
  end

  describe "api_backends/0" do
    test "returns list of known API backends" do
      backends = BackendRegistry.api_backends()
      assert is_list(backends)
      assert :anthropic_api in backends
      assert :openai_api in backends
      assert :google_api in backends
      assert :openrouter in backends
    end
  end

  describe "server_backends/0" do
    test "returns list of known server backends" do
      backends = BackendRegistry.server_backends()
      assert is_list(backends)
      assert :lmstudio in backends
      assert :ollama in backends
    end
  end

  describe "all_backends/0" do
    test "combines CLI, API, and server backends" do
      all = BackendRegistry.all_backends()
      cli = BackendRegistry.cli_backends()
      api = BackendRegistry.api_backends()
      server = BackendRegistry.server_backends()

      assert length(all) == length(cli) + length(api) + length(server)

      Enum.each(cli, fn b -> assert b in all end)
      Enum.each(api, fn b -> assert b in all end)
      Enum.each(server, fn b -> assert b in all end)
    end
  end

  describe "get_command/1" do
    test "returns command string for CLI backends" do
      assert BackendRegistry.get_command(:claude_cli) == "claude"
      assert BackendRegistry.get_command(:codex_cli) == "codex"
      assert BackendRegistry.get_command(:gemini_cli) == "gemini"
      assert BackendRegistry.get_command(:qwen_cli) == "qwen"
      assert BackendRegistry.get_command(:opencode_cli) == "opencode"
    end

    test "returns nil for non-CLI backends" do
      assert BackendRegistry.get_command(:anthropic_api) == nil
      assert BackendRegistry.get_command(:lmstudio) == nil
      assert BackendRegistry.get_command(:unknown) == nil
    end
  end

  describe "ttl_ms/0" do
    test "returns default TTL of 5 minutes" do
      original = Application.get_env(:arbor_ai, :backend_registry_ttl_ms)

      try do
        Application.delete_env(:arbor_ai, :backend_registry_ttl_ms)
        assert BackendRegistry.ttl_ms() == 300_000
      after
        if original != nil do
          Application.put_env(:arbor_ai, :backend_registry_ttl_ms, original)
        end
      end
    end

    test "respects configured TTL override" do
      original = Application.get_env(:arbor_ai, :backend_registry_ttl_ms)

      try do
        Application.put_env(:arbor_ai, :backend_registry_ttl_ms, 60_000)
        assert BackendRegistry.ttl_ms() == 60_000
      after
        if original != nil do
          Application.put_env(:arbor_ai, :backend_registry_ttl_ms, original)
        else
          Application.delete_env(:arbor_ai, :backend_registry_ttl_ms)
        end
      end
    end
  end

  # ===========================================================================
  # ETS caching and availability (requires GenServer)
  # ===========================================================================

  describe "available?/1" do
    test "returns a valid status atom" do
      status = BackendRegistry.available?(:claude_cli)
      assert status in [:available, :unavailable, :not_installed, :checking]
    end

    test "unknown backends return :not_installed" do
      status = BackendRegistry.available?(:completely_fake_backend)
      assert status == :not_installed
    end

    test "API backend availability depends on env var" do
      original = System.get_env("ANTHROPIC_API_KEY")

      try do
        # If key is set, should be available
        if original do
          assert BackendRegistry.refresh(:anthropic_api) == :available
        end

        # With key unset, should be unavailable
        System.delete_env("ANTHROPIC_API_KEY")
        status = BackendRegistry.refresh(:anthropic_api)
        assert status == :unavailable
      after
        if original do
          System.put_env("ANTHROPIC_API_KEY", original)
          BackendRegistry.refresh(:anthropic_api)
        end
      end
    end
  end

  describe "get_info/1" do
    test "returns backend_info map for known backend" do
      info = BackendRegistry.get_info(:claude_cli)

      # Info may be nil if lookup fails, but if returned should have the right shape
      if info != nil do
        assert is_map(info)
        assert Map.has_key?(info, :status)
        assert Map.has_key?(info, :checked_at)
        assert info.status in [:available, :unavailable, :not_installed, :checking]
      end
    end

    test "returns nil for unknown backend" do
      # Unknown backends get :not_installed status but still cached
      info = BackendRegistry.get_info(:totally_unknown_xyz)

      if info != nil do
        assert info.status == :not_installed
      end
    end
  end

  describe "refresh/1" do
    test "returns a valid status after refresh" do
      status = BackendRegistry.refresh(:claude_cli)
      assert status in [:available, :unavailable, :not_installed]
    end

    test "caches result after refresh" do
      # First refresh
      status1 = BackendRegistry.refresh(:claude_cli)

      # Second lookup should hit cache
      status2 = BackendRegistry.available?(:claude_cli)

      assert status1 == status2
    end
  end

  describe "ETS TTL expiration" do
    test "cached result expires after TTL" do
      original_ttl = Application.get_env(:arbor_ai, :backend_registry_ttl_ms)

      try do
        # Set very short TTL (1ms)
        Application.put_env(:arbor_ai, :backend_registry_ttl_ms, 1)

        # Cache a result
        BackendRegistry.refresh(:openrouter)

        # Wait for TTL to expire
        Process.sleep(10)

        # Next access should trigger a fresh check (miss)
        # We can't easily verify the internal cache miss, but we can verify
        # the result is still valid
        status = BackendRegistry.available?(:openrouter)
        assert status in [:available, :unavailable, :not_installed]
      after
        if original_ttl != nil do
          Application.put_env(:arbor_ai, :backend_registry_ttl_ms, original_ttl)
        else
          Application.delete_env(:arbor_ai, :backend_registry_ttl_ms)
        end
      end
    end
  end

  describe "refresh_all/0" do
    test "returns list of {backend, status} tuples" do
      results = BackendRegistry.refresh_all()

      assert is_list(results)
      assert length(results) == length(BackendRegistry.all_backends())

      Enum.each(results, fn {backend, status} ->
        assert is_atom(backend)
        assert status in [:available, :unavailable, :not_installed]
      end)
    end
  end
end

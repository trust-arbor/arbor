defmodule Arbor.Contracts.AI.RuntimeContractTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.AI.{Capabilities, RuntimeContract}

  describe "new/1" do
    test "creates contract from keyword list" do
      {:ok, contract} =
        RuntimeContract.new(
          provider: "anthropic",
          display_name: "Anthropic API",
          type: :api,
          env_vars: [%{name: "ANTHROPIC_API_KEY", required: true}]
        )

      assert contract.provider == "anthropic"
      assert contract.display_name == "Anthropic API"
      assert contract.type == :api
      assert length(contract.env_vars) == 1
    end

    test "creates contract from map" do
      {:ok, contract} =
        RuntimeContract.new(%{
          provider: "claude_cli",
          display_name: "Claude CLI",
          type: :cli,
          cli_tools: [%{name: "claude", install_hint: "npm i -g @anthropic-ai/claude-code"}]
        })

      assert contract.provider == "claude_cli"
      assert contract.type == :cli
      assert length(contract.cli_tools) == 1
    end

    test "defaults type to :api" do
      {:ok, contract} =
        RuntimeContract.new(provider: "test", display_name: "Test")

      assert contract.type == :api
    end

    test "defaults lists to empty" do
      {:ok, contract} =
        RuntimeContract.new(provider: "test", display_name: "Test")

      assert contract.env_vars == []
      assert contract.cli_tools == []
      assert contract.probes == []
    end

    test "accepts capabilities struct" do
      caps = Capabilities.new(streaming: true, thinking: true)

      {:ok, contract} =
        RuntimeContract.new(
          provider: "claude_cli",
          display_name: "Claude CLI",
          type: :cli,
          capabilities: caps
        )

      assert contract.capabilities.streaming == true
      assert contract.capabilities.thinking == true
    end

    test "validates required provider field" do
      assert {:error, {:missing_required_field, :provider}} =
               RuntimeContract.new(display_name: "Test")
    end

    test "validates required display_name field" do
      assert {:error, {:missing_required_field, :display_name}} =
               RuntimeContract.new(provider: "test")
    end

    test "validates type enum" do
      assert {:error, {:invalid_type, :invalid}} =
               RuntimeContract.new(provider: "test", display_name: "Test", type: :invalid)
    end

    test "accepts all valid types" do
      for type <- [:api, :cli, :local] do
        assert {:ok, _} =
                 RuntimeContract.new(provider: "test", display_name: "Test", type: type)
      end
    end
  end

  describe "check/1" do
    test "passes with no requirements" do
      {:ok, contract} = RuntimeContract.new(provider: "test", display_name: "Test")
      assert {:ok, results} = RuntimeContract.check(contract)
      assert results.env_vars == :skipped
      assert results.cli_tools == :skipped
      assert results.probes == :skipped
    end

    test "passes when env var is set" do
      System.put_env("ARBOR_TEST_CONTRACT_KEY", "test-value")

      {:ok, contract} =
        RuntimeContract.new(
          provider: "test",
          display_name: "Test",
          env_vars: [%{name: "ARBOR_TEST_CONTRACT_KEY", required: true}]
        )

      assert {:ok, results} = RuntimeContract.check(contract)
      assert results.env_vars == :ok

      System.delete_env("ARBOR_TEST_CONTRACT_KEY")
    end

    test "fails when required env var is missing" do
      {:ok, contract} =
        RuntimeContract.new(
          provider: "test",
          display_name: "Test",
          env_vars: [%{name: "ARBOR_DEFINITELY_NOT_SET_XYZ", required: true}]
        )

      assert {:error, failures} = RuntimeContract.check(contract)
      assert Keyword.has_key?(failures, :env_vars)
    end

    test "passes when optional env var is missing" do
      {:ok, contract} =
        RuntimeContract.new(
          provider: "test",
          display_name: "Test",
          env_vars: [%{name: "ARBOR_DEFINITELY_NOT_SET_XYZ", required: false}]
        )

      assert {:ok, results} = RuntimeContract.check(contract)
      assert results.env_vars == :ok
    end

    test "checks CLI tool availability" do
      {:ok, contract} =
        RuntimeContract.new(
          provider: "test",
          display_name: "Test",
          type: :cli,
          cli_tools: [%{name: "definitely_not_a_real_binary_xyz", install_hint: "brew install it"}]
        )

      assert {:error, failures} = RuntimeContract.check(contract)
      assert Keyword.has_key?(failures, :cli_tools)
    end

    test "passes when CLI tool exists" do
      # "ls" should exist on any system
      {:ok, contract} =
        RuntimeContract.new(
          provider: "test",
          display_name: "Test",
          type: :cli,
          cli_tools: [%{name: "ls", install_hint: nil}]
        )

      assert {:ok, results} = RuntimeContract.check(contract)
      assert results.cli_tools == :ok
    end

    test "fails when HTTP probe doesn't respond" do
      {:ok, contract} =
        RuntimeContract.new(
          provider: "test",
          display_name: "Test",
          type: :local,
          probes: [%{type: :http, url: "http://localhost:59999/nonexistent", timeout_ms: 500}]
        )

      assert {:error, failures} = RuntimeContract.check(contract)
      assert Keyword.has_key?(failures, :probes)
    end
  end

  describe "available?/1" do
    test "returns true when all checks pass" do
      {:ok, contract} = RuntimeContract.new(provider: "test", display_name: "Test")
      assert RuntimeContract.available?(contract)
    end

    test "returns false when checks fail" do
      {:ok, contract} =
        RuntimeContract.new(
          provider: "test",
          display_name: "Test",
          env_vars: [%{name: "ARBOR_DEFINITELY_NOT_SET_XYZ", required: true}]
        )

      refute RuntimeContract.available?(contract)
    end
  end
end

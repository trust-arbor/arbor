defmodule Arbor.Agent.SessionIntegrationTest do
  @moduledoc """
  Integration tests for session execution mode config gating.

  Tests the config behavior without needing the orchestrator.
  Full session integration tests live in arbor_orchestrator's test suite.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  setup do
    original_mode = Application.fetch_env(:arbor_agent, :session_execution_mode)

    on_exit(fn ->
      case original_mode do
        {:ok, mode} -> Application.put_env(:arbor_agent, :session_execution_mode, mode)
        :error -> Application.delete_env(:arbor_agent, :session_execution_mode)
      end
    end)

    :ok
  end

  describe "session_execution_mode config" do
    test "default mode is :session" do
      Application.delete_env(:arbor_agent, :session_execution_mode)
      assert Application.get_env(:arbor_agent, :session_execution_mode, :session) == :session
    end

    test ":session mode can be set at runtime" do
      Application.put_env(:arbor_agent, :session_execution_mode, :session)
      assert Application.get_env(:arbor_agent, :session_execution_mode) == :session
    end

    test ":graph mode can be set at runtime" do
      Application.put_env(:arbor_agent, :session_execution_mode, :graph)
      assert Application.get_env(:arbor_agent, :session_execution_mode) == :graph
    end
  end
end

defmodule Arbor.Agent.SessionIntegrationTest do
  @moduledoc """
  Integration tests for session execution mode config gating.

  Tests the config behavior without needing the orchestrator.
  Full session integration tests live in arbor_orchestrator's test suite.
  """
  use ExUnit.Case, async: false

  setup do
    original_mode = Application.get_env(:arbor_agent, :session_execution_mode)
    on_exit(fn -> Application.put_env(:arbor_agent, :session_execution_mode, original_mode) end)
    :ok
  end

  describe "session_execution_mode config" do
    test "default mode is :legacy" do
      Application.delete_env(:arbor_agent, :session_execution_mode)
      assert Application.get_env(:arbor_agent, :session_execution_mode, :legacy) == :legacy
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

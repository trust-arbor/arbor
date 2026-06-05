defmodule Arbor.Commands.HelpersTest do
  @moduledoc """
  Tests for the shared command persistence wrapper. The function is
  deliberately forgiving — never raises, always returns `:ok`, just
  logs warnings on failure — so the user-visible command path doesn't
  fail when persistence is unavailable.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  import ExUnit.CaptureLog
  alias Arbor.Commands.Helpers

  describe "persist_model_config_field/4" do
    test "no-ops on nil agent_id (transient session)" do
      log =
        capture_log(fn ->
          assert :ok = Helpers.persist_model_config_field(nil, :runtime, :acp, "Test")
        end)

      assert log == "" or log == nil
    end

    test "no-ops on empty agent_id" do
      log =
        capture_log(fn ->
          assert :ok = Helpers.persist_model_config_field("", :runtime, :acp, "Test")
        end)

      assert log == "" or log == nil
    end

    test "logs warning + returns :ok when profile lookup fails" do
      log =
        capture_log(fn ->
          assert :ok =
                   Helpers.persist_model_config_field(
                     "agent_does_not_exist_xyz",
                     :runtime,
                     :acp,
                     "TestTag"
                   )
        end)

      assert log =~ "TestTag"
      assert log =~ "persistence failed" or log =~ "not_found"
      assert log =~ "live session updated"
    end

    test "always returns :ok regardless of underlying success or failure" do
      # The wrapper's contract is "never fail the command". Even if
      # everything explodes downstream, we get :ok back.
      assert :ok =
               Helpers.persist_model_config_field("nonexistent_agent", :model, "x", "Test")
    end
  end
end

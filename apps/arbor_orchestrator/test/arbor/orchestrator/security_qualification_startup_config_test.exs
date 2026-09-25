defmodule Arbor.Orchestrator.SecurityQualificationStartupConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @key "ARBOR_SECURITY_QUALIFICATION_PROFILES"
  @principal "agent_" <> String.duplicate("a", 64)
  @path Path.expand("../../../../../config/runtime.exs", __DIR__)

  setup do
    prior = System.get_env(@key)

    on_exit(fn ->
      if prior, do: System.put_env(@key, prior), else: System.delete_env(@key)
    end)

    :ok
  end

  test "host startup restores exact turn and heartbeat requirements" do
    System.put_env(
      @key,
      JSON.encode!(%{
        @principal => %{
          "turn" => %{"run_id" => "reviewed_turn"},
          "heartbeat" => %{"run_id" => "reviewed_heartbeat"}
        }
      })
    )

    config = Config.Reader.read!(@path, env: :dev, imports: :disabled)

    assert config[:arbor_orchestrator][:security_qualification_profiles] == %{
             @principal => %{
               turn: %{run_id: "reviewed_turn"},
               heartbeat: %{run_id: "reviewed_heartbeat"}
             }
           }
  end

  test "invalid present policy refuses startup" do
    for value <- [
          "",
          "{",
          "[]",
          JSON.encode!(%{"unknown" => %{}}),
          JSON.encode!(%{@principal => %{"other" => %{"run_id" => "run"}}}),
          JSON.encode!(%{@principal => %{"turn" => %{"run_id" => "../run"}}})
        ] do
      System.put_env(@key, value)

      assert_raise ArgumentError, ~r/invalid ARBOR_SECURITY_QUALIFICATION_PROFILES/, fn ->
        Config.Reader.read!(@path, env: :dev, imports: :disabled)
      end
    end
  end

  test "unset deployment policy does not invent a qualification" do
    System.delete_env(@key)

    assert Config.Reader.read!(@path, env: :dev, imports: :disabled)[:arbor_orchestrator][
             :security_qualification_profiles
           ] == nil
  end

  test "test runtimes ignore ambient deployment requirements" do
    System.put_env(@key, "invalid-live-value")

    assert Config.Reader.read!(@path, env: :test, imports: :disabled)[:arbor_orchestrator][
             :security_qualification_profiles
           ] == nil
  end
end

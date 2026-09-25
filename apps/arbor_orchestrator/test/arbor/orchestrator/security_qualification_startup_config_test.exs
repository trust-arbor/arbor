defmodule Arbor.Orchestrator.SecurityQualificationStartupConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @key "ARBOR_SECURITY_QUALIFICATION_PROFILES"
  @principal "agent_" <> String.duplicate("a", 64)
  @path Path.expand("../../../../../config/runtime.exs", __DIR__)
  # The entire runtime file is the boundary under test. Clear its literal env
  # inputs so another opt-in bridge cannot consume a developer's configuration.
  # Dynamic companion fields are unreachable with their opt-in flags cleared.
  @env_keys Regex.scan(~r/System\.(?:get_env|fetch_env!)\("([A-Z0-9_]+)"/, File.read!(@path))
            |> Enum.map(fn [_, key] -> key end)
            |> Enum.uniq()

  setup do
    prior = Map.new(@env_keys, &{&1, System.get_env(&1)})
    Enum.each(@env_keys, &System.delete_env/1)

    root =
      Path.join(System.tmp_dir!(), "qualification-config-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    System.put_env("ARBOR_HOME", root)

    on_exit(fn ->
      Enum.each(prior, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "host startup restores exact turn and heartbeat requirements", %{root: root} do
    System.put_env(
      @key,
      JSON.encode!(%{
        @principal => %{
          "turn" => %{"run_id" => "reviewed_turn"},
          "heartbeat" => %{"run_id" => "reviewed_heartbeat"}
        }
      })
    )

    config = read_runtime(root, :dev)

    assert config[:arbor_orchestrator][:security_qualification_profiles] == %{
             @principal => %{
               turn: %{run_id: "reviewed_turn"},
               heartbeat: %{run_id: "reviewed_heartbeat"}
             }
           }
  end

  test "invalid present policy refuses startup", %{root: root} do
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
        read_runtime(root, :dev)
      end
    end
  end

  test "unset deployment policy does not invent a qualification", %{root: root} do
    System.delete_env(@key)

    assert read_runtime(root, :dev)[:arbor_orchestrator][
             :security_qualification_profiles
           ] == nil
  end

  test "test runtimes ignore ambient deployment requirements", %{root: root} do
    System.put_env(@key, "invalid-live-value")

    assert read_runtime(root, :test)[:arbor_orchestrator][
             :security_qualification_profiles
           ] == nil
  end

  defp read_runtime(root, env) do
    File.cd!(root, fn ->
      Config.Reader.read!(@path, env: env, target: :host, imports: :disabled)
    end)
  end
end

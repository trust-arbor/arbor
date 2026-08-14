defmodule Arbor.Monitor.K1DSourceGuardTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "production Monitor lib names no higher-band Agent or Comms modules" do
    root = find_root(__DIR__)
    files = Path.wildcard(Path.join(root, "apps/arbor_monitor/lib/**/*.ex"))
    assert files != []

    Enum.each(files, fn path ->
      contents = File.read!(path)
      relative = Path.relative_to(path, root)
      # Pre-existing SupervisorMonitor watches Arbor.Agent.Supervisor; that
      # is outside K1D. Strip it so the Agent facade/Lifecycle names stay banned.
      agent_scan = String.replace(contents, "Arbor.Agent.Supervisor", "")

      refute contents =~ "Arbor.Comms", "#{relative} names Arbor.Comms"
      refute agent_scan =~ "Arbor.Agent", "#{relative} names Arbor.Agent"
      refute contents =~ "Arbor.Agent.Lifecycle", "#{relative} names Arbor.Agent.Lifecycle"
      refute contents =~ "Elixir.Arbor.Comms", "#{relative} names Elixir.Arbor.Comms"
      refute contents =~ "Elixir.Arbor.Agent", "#{relative} names Elixir.Arbor.Agent"

      refute(
        Regex.match?(~r/Module\.concat[^\n]*(Comms|Agent|Lifecycle)/, contents),
        "#{relative} hides Comms, Agent, or Lifecycle via Module.concat"
      )
    end)
  end

  defp find_root(dir) do
    cond do
      File.exists?(Path.join([dir, "apps", "arbor_contracts", "mix.exs"])) ->
        dir

      Path.dirname(dir) == dir ->
        flunk("umbrella root not found from #{__DIR__}")

      true ->
        find_root(Path.dirname(dir))
    end
  end
end

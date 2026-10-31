Code.require_file(Path.expand("../../../build_support/optional_apps.exs", __DIR__))

defmodule Arbor.OptionalAppsTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @root Path.expand("../../..", __DIR__)
  @voice_apps [:arbor_voice, :arbor_multimedia]

  test "voice requires an explicit build opt-in" do
    for value <- [nil, "", "false", "0"] do
      refute Arbor.OptionalApps.voice_enabled?(%{"ARBOR_VOICE" => value})
    end

    for value <- ["true", "1"] do
      assert Arbor.OptionalApps.voice_enabled?(%{"ARBOR_VOICE" => value})
    end

    assert_raise ArgumentError, ~r/ARBOR_VOICE must be true or false/, fn ->
      Arbor.OptionalApps.voice_enabled?(%{"ARBOR_VOICE" => "tru"})
    end
  end

  test "default discovery excludes voice even though its source is installed" do
    path = Path.join(@root, "apps")
    apps = Arbor.OptionalApps.apps(path, %{})

    assert :arbor_dashboard in apps
    assert :arbor_agent in apps
    assert :arbor_trust_host in apps
    assert :arbor_historian_host in apps
    refute :arbor_trust in apps
    refute :arbor_historian in apps
    refute Enum.any?(@voice_apps, &(&1 in apps))

    enabled = Arbor.OptionalApps.apps(path, %{"ARBOR_VOICE" => "true"})
    assert Enum.all?(@voice_apps, &(&1 in enabled))
    assert Enum.sort(enabled -- @voice_apps) == apps
  end

  test "real Mix projects select matching umbrella apps and dashboard dependencies" do
    for {value, enabled?} <- [{nil, false}, {"false", false}, {"true", true}] do
      {apps, deps} = mix_selection(value)

      assert "arbor_dashboard" in apps
      assert "arbor_agent" in deps

      for app <- @voice_apps do
        assert Atom.to_string(app) in apps == enabled?
        assert Atom.to_string(app) in deps == enabled?
      end
    end
  end

  defp mix_selection(value) do
    # Fresh Mix state per selector. No fetching, compilation, application startup,
    # or mutation of the test VM's environment/project stack.
    script = """
    Mix.start()
    Code.require_file("mix.exs")
    apps = Enum.map(Map.keys(Mix.Project.apps_paths()), &Atom.to_string/1)
    # Simulate dotenv loading after the root project. Child selection must
    # still use the original build selector, including when it was unset.
    System.put_env("ARBOR_VOICE", if(Arbor.OptionalApps.voice_enabled?(), do: "false", else: "true"))
    Mix.Project.in_project(:arbor_dashboard, "apps/arbor_dashboard", fn _ ->
      deps = Enum.map(Mix.Project.config()[:deps], &(elem(&1, 0) |> Atom.to_string()))
      result = {apps, deps} |> :erlang.term_to_binary() |> Base.encode64()
      IO.puts("SELECTION=" <> result)
    end)
    """

    {output, status} =
      System.cmd("elixir", ["-e", script],
        cd: @root,
        env: [{"ARBOR_VOICE", value}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    [_, encoded] = Regex.run(~r/^SELECTION=(.+)$/m, output)
    :erlang.binary_to_term(Base.decode64!(encoded), [:safe])
  end
end

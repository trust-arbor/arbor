defmodule Mix.Tasks.Arbor.Packaging.AppEnvReleaseProbeTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.AppEnvReleaseProbe
  alias Mix.Tasks.Arbor.Packaging.AppEnvReleaseProbe, as: Task

  @moduletag :fast

  test "rejects unknown options" do
    assert {:error, {:arguments, :unknown_or_invalid_option}} =
             Task.execute(["--check"])
  end

  test "production execute refuses runtime hooks" do
    assert {:error, {:production_task_forbids_runtime_hooks, _}} =
             Task.execute(["--json"], inventory: %{})
  end
end

defmodule Mix.Tasks.Arbor.Packaging.AppEnvReleaseProbeProductionPathTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.AppEnvReleaseProbe

  @moduletag :slow
  @moduletag timeout: 300_000

  # Nested `mix compile` + `mix release` of five apps will OOM/timeout a
  # root-wide umbrella suite (validator exit 137). The Mix task remains the
  # executable artifact-side probe. Opt in with ARBOR_APP_ENV_PROBES=1.
  if System.get_env("ARBOR_APP_ENV_PROBES") != "1" do
    @moduletag skip: "set ARBOR_APP_ENV_PROBES=1 or run mix arbor.packaging.app_env_release_probe"
  end

  test "assembled release evals owner runtime values from the artifact" do
    root = umbrella_root()
    lock_path = Path.join(root, "mix.lock")
    before_lock = File.read!(lock_path)
    before_mtime = File.stat!(lock_path).mtime

    assert {:ok, payload} = AppEnvReleaseProbe.run(root: root, json: true)

    assert payload["common"]["start_children"] == false
    assert payload["common"]["skill_embedding_module"] == nil
    assert payload["common"]["skill_dirs"] == nil
    assert payload["common"]["skill_embedding_dimensions"] == 768
    assert payload["common"]["tool_catalog_enabled"] == true

    assert payload["signals"]["start_children"] == false
    assert payload["signals"]["durable_sink_module"] == nil

    assert payload["signals"]["authorizer"] ==
             "Elixir.Arbor.Signals.Adapters.CapabilityAuthorizer"

    assert payload["signals"]["relay_enabled"] == false

    assert payload["monitor"]["start_children"] == false
    assert payload["monitor"]["channel_bridge_module"] == nil
    assert payload["monitor"]["polling_interval"] == 5_000
    assert payload["monitor"]["signal_emission_enabled"] == false

    assert "arbor_kernel" in payload["started"]

    assert File.read!(lock_path) == before_lock
    assert File.stat!(lock_path).mtime == before_mtime
  end

  defp umbrella_root do
    find_root(__DIR__)
  end

  defp find_root(dir) do
    cond do
      File.regular?(Path.join([dir, "apps", "arbor_kernel", "mix.exs"])) -> dir
      Path.dirname(dir) == dir -> raise "umbrella root not found"
      true -> find_root(Path.dirname(dir))
    end
  end
end

defmodule Arbor.Security.OIDC.ConfigHostTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  test "security regression: runtime.exs stays app-agnostic while arbor.orchestrate uses the authority" do
    root = find_root(__DIR__)
    runtime = File.read!(Path.join(root, "config/runtime.exs"))

    orchestrate =
      File.read!(Path.join(root, "apps/arbor_orchestrator/lib/mix/tasks/arbor.orchestrate.ex"))

    refute runtime =~ "Arbor.Security.OIDC.Config.allow_http?"
    refute runtime =~ "allow_http: allow_http"
    assert orchestrate =~ "Arbor.Security.OIDC.Config.allow_http?"
    assert orchestrate =~ "allow_http: allow_http"
  end

  test "security regression: runtime config evaluates without Security application BEAMs" do
    root = find_root(__DIR__)
    runtime_path = Path.join(root, "config/runtime.exs")
    elixir = System.find_executable("elixir") || flunk("elixir executable not found")
    expression = "Config.Reader.read!(#{inspect(runtime_path)}, env: :test)"

    cwd =
      Path.join(System.tmp_dir!(), "arbor_runtime_config_#{System.unique_integer([:positive])}")

    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)

    {output, status} =
      System.cmd(elixir, ["-e", expression],
        cd: cwd,
        env: [
          {"OIDC_ISSUER", "http://localhost:8080"},
          {"OIDC_CLIENT_ID", "runtime-boundary-test"},
          {"OIDC_ALLOW_HTTP", "true"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp find_root(dir) do
    cond do
      File.exists?(Path.join([dir, "packages", "arbor_kernel", "mix.exs"])) ->
        dir

      Path.dirname(dir) == dir ->
        flunk("umbrella root not found from #{__DIR__}")

      true ->
        find_root(Path.dirname(dir))
    end
  end
end

defmodule Mix.Tasks.Arbor.ConfigSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-017"

  @tag :fast
  @tag :security_regression
  @tag spec: "KSEC-017"
  test "security regression: application environment output redacts secret values" do
    session_secret = "plain-random-session-material"
    cookie = "plain-random-cookie-material"
    password = "plain-random-password-material"

    top_level =
      Mix.Tasks.Arbor.Config.format_entry(:session_token_secret, session_secret)

    nested =
      Mix.Tasks.Arbor.Config.format_entry(:provider_config, %{
        cookie: cookie,
        credentials: [password: password],
        endpoint: "https://example.invalid"
      })

    refute top_level =~ session_secret
    refute nested =~ cookie
    refute nested =~ password
    assert top_level =~ "[REDACTED]"
    assert nested =~ "[REDACTED]"
    assert nested =~ "provider_config"
  end

  @tag :external
  @tag :integration
  @tag :security_regression
  @tag :slow
  test "security regression: public config task never prints a runtime secret" do
    secret = "config-task-secret-" <> Base.url_encode64(:crypto.strong_rand_bytes(18))
    epmd_port = unused_tcp_port()

    code_path_args =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&String.contains?(&1, "/_build/test/lib/"))
      |> Enum.flat_map(&["-pa", &1])

    script = """
    Mix.start()
    {_, 0} = System.cmd("epmd", ["-daemon"])
    target = Mix.Tasks.Arbor.Helpers.full_node_name()
    {:ok, _pid} = Node.start(target, :longnames)
    Application.put_env(:arbor_kernel_runtime, :session_token_secret, #{inspect(secret)})
    Mix.Tasks.Arbor.Config.run(["arbor_kernel_runtime"])
    Node.stop()
    Process.sleep(50)
    System.cmd("epmd", ["-kill"])
    """

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        code_path_args ++ ["-e", script],
        env: [
          {"ARBOR_COOKIE", "config-regression-cookie"},
          {"ARBOR_NODE_HOST", "127.0.0.1"},
          {"ERL_EPMD_PORT", Integer.to_string(epmd_port)}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "session_token_secret"
    assert output =~ "[REDACTED]"
    refute output =~ secret
  end

  defp unused_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end

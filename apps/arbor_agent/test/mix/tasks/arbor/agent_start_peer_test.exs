defmodule Mix.Tasks.Arbor.AgentStartPeerTest do
  @moduledoc """
  The newcomer path on a fresh server, through the CLI seams:
  `mix arbor.user.init` (genesis), then `mix arbor.agent start`.

  The server is a fresh peer node (`Arbor.Agent.Test.SecurityPeer`) with
  durable private authority state and the agent runtime. The operator's key
  exists only in the key file this VM writes. Every server call crosses to the
  peer as a serialized term and is recorded, so the test also proves no
  private key crossed. Sessions are not started on the peer (no LLM); the
  start options for that are added server-side by the test's remote, outside
  the signed request.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :slow
  @moduletag timeout: 300_000

  alias Arbor.Agent.Test.SecurityPeer
  alias Arbor.Common.SafePath

  @local_opts [start_session: false, start_heartbeat: false, recover_session: false]

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    dir = private_dir!()
    peer = SecurityPeer.start!(Path.join(dir, "server"), agent_runtime: true)

    on_exit(fn ->
      Mix.shell(previous_shell)
      SecurityPeer.stop(peer)
      File.rm_rf!(dir)
    end)

    {:ok, peer: peer, dir: dir}
  end

  test "security regression: a fresh install reaches a started agent with the key only in the key file",
       %{peer: peer, dir: dir} do
    key_path = Path.join(dir, "operator.key")
    template = "newcomer-#{System.unique_integer([:positive])}"

    :ok =
      SecurityPeer.call(peer, Arbor.Agent.TemplateStore, :set_templates_dir, [
        Path.join(dir, "templates")
      ])

    :ok =
      SecurityPeer.call(peer, Arbor.Agent, :put_template, [
        template,
        %{
          "name" => template,
          "character" => %{"name" => "River"},
          "required_capabilities" => [],
          "tools" => []
        }
      ])

    # Before user.init the operator is not registered, so even a well-formed
    # signed start is refused.
    {_public, early_key} = :crypto.generate_key(:eddsa, :ed25519)
    early_path = Path.join(dir, "early.key")
    principal = SecurityPeer.call(peer, Arbor.Security, :local_human_principal_id, [[]])

    {:ok, _} =
      Arbor.Security.write_key_file(early_path, %{agent_id: principal, private_key: early_key})

    assert {:error, _calls} =
             run(peer, Mix.Tasks.Arbor.Agent, :start_operator, [
               template,
               start_opts(early_path)
             ])

    drain()
    File.rm!(early_path)

    # 1. mix arbor.user.init: key generated here, public key registered, genesis.
    assert {:ok, calls} =
             run(peer, Mix.Tasks.Arbor.User.Init, :init_operator, [[key_file: key_path]])

    assert drain() =~ "Genesis: granted arbor://** to #{principal}"

    assert {:ok, %{agent_id: ^principal, private_key: private_key}} =
             Arbor.Security.parse_operator_key_file_contents(File.read!(key_path))

    refute_secret_crossed(calls, private_key)

    # 2. mix arbor.agent start: signed here, verified there, started there.
    assert {:ok, calls} =
             run(peer, Mix.Tasks.Arbor.Agent, :start_operator, [template, start_opts(key_path)])

    assert drain() =~ "Started agent 'River'"
    refute_secret_crossed(calls, private_key)

    assert [{:ok, agent_id, _pid, :created}] =
             for(
               {Arbor.Agent, :submit_signed_lifecycle_request, _args, result} <- calls,
               do: result
             )

    assert is_pid(SecurityPeer.call(peer, Arbor.Agent.BranchSupervisor, :whereis, [agent_id]))

    # The operator owns the conversation (`mix arbor.agent chat` authorizes
    # this resource), and the server still holds no key for the operator.
    assert {:ok, :authorized} =
             SecurityPeer.call(peer, Arbor.Security, :authorize, [
               principal,
               "arbor://chat/agent/#{agent_id}",
               :write,
               []
             ])

    assert {:error, :no_signing_key} =
             SecurityPeer.call(peer, Arbor.Security, :signing_key_status, [principal])
  end

  defp start_opts(key_path),
    do: [key_file: key_path, provider: "openrouter", model: "sealed-no-provider"]

  # Runs one CLI seam here with a remote that crosses to the peer.
  defp run(peer, module, function, args) do
    Process.put(:peer_calls, [])

    remote = fn mod, fun, call_args ->
      call_args =
        if {mod, fun} == {Arbor.Agent, :submit_signed_lifecycle_request},
          do: call_args ++ [@local_opts],
          else: call_args

      result = SecurityPeer.call(peer, mod, fun, call_args)
      Process.put(:peer_calls, [{mod, fun, call_args, result} | Process.get(:peer_calls)])
      result
    end

    result = apply(module, function, args ++ [remote])
    calls = Enum.reverse(Process.get(:peer_calls))
    if result == :ok, do: {:ok, calls}, else: {:error, calls}
  end

  defp refute_secret_crossed(calls, private_key) do
    for {_m, f, args, result} <- calls do
      assert :binary.match(:erlang.term_to_binary({args, result}), private_key) == :nomatch,
             "private key material crossed the server boundary in #{f}"
    end
  end

  defp drain do
    receive do
      {:mix_shell, _kind, [message]} -> message <> "\n" <> drain()
    after
      0 -> ""
    end
  end

  defp private_dir! do
    {:ok, system_tmp} = SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path = Path.join(system_tmp, "arbor-agent-start-#{token}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end
end

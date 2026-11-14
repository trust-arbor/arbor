defmodule Mix.Tasks.Arbor.User.InitTest do
  @moduledoc """
  `mix arbor.user.init` against a real Arbor security server.

  The server is a fresh peer node (`Arbor.Agent.Test.SecurityPeer`) running
  `:arbor_capabilities` with private, durable authority state and the
  local-human gate open, as on a dev install. The task's core (`init_operator/2`) runs in this VM as the CLI
  does, and every server call crosses to the peer as a serialized term
  through `:peer.call/5`, as `:rpc` would carry it. Each call is recorded so
  the test can prove that no private key crossed in either direction.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :slow
  @moduletag timeout: 180_000

  alias Arbor.Agent.Test.SecurityPeer
  alias Arbor.Common.SafePath
  alias Mix.Tasks.Arbor.User.Init

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    dir = private_dir!()
    peer = SecurityPeer.start!(Path.join(dir, "server"))

    on_exit(fn ->
      Mix.shell(previous_shell)
      SecurityPeer.stop(peer)
      File.rm_rf!(dir)
    end)

    {:ok, peer: peer, dir: dir}
  end

  test "security regression: user.init generates the key locally, registers only its public half, and completes genesis",
       %{peer: peer, dir: dir} do
    key_path = Path.join(dir, "operator.key")
    opts = [key_file: key_path]
    principal = peer_call(peer, Arbor.Security, :local_human_principal_id, [[]])

    # Gate closed: refused before any key is generated.
    peer_put_env(peer, :allow_local_human_identity, false)
    assert {:error, calls} = run_init(peer, opts)
    assert errors() =~ "Local human identities are disabled"
    refute File.exists?(key_path)
    assert [:local_human_identity_status] = called_functions(calls)

    peer_put_env(peer, :allow_local_human_identity, true)

    # First run: key generated here, public key registered, genesis granted.
    assert {:ok, calls} = run_init(peer, opts)
    output = infos()

    assert %File.Stat{mode: mode} = File.stat!(key_path)
    assert Bitwise.band(mode, 0o777) == 0o600

    assert {:ok, %{agent_id: ^principal, private_key: private_key}} =
             Arbor.Security.parse_operator_key_file_contents(File.read!(key_path))

    {public_key, _} = :crypto.generate_key(:eddsa, :ed25519, private_key)

    assert {:ok, %{principal_id: ^principal, public_key: ^public_key}} =
             peer_call(peer, Arbor.Security, :local_human_identity_status, [[]])

    # The server holds no private key for the operator.
    assert {:error, :no_signing_key} =
             peer_call(peer, Arbor.Security, :signing_key_status, [principal])

    assert output =~ "Generated an Ed25519 keypair locally for #{principal}"
    assert output =~ "Registered local operator identity: #{principal}"
    assert output =~ "Genesis: granted arbor://** to #{principal}"
    assert [_root] = root_caps(peer, principal)
    # The mutation-bound proof `mix arbor.user.link` signs from this key file
    # verifies against the registered key and authorizes alias management.
    assert output =~ "Verified: #{principal} can manage identity aliases"

    assert [
             :local_human_identity_status,
             :register_local_human_identity,
             :complete_local_genesis,
             :authorize
           ] = called_functions(calls)

    refute_secret_crossed(calls, private_key)

    # Re-run with the same key file: idempotent, nothing new granted.
    key_bytes = File.read!(key_path)
    assert {:ok, calls} = run_init(peer, opts)
    output = infos()
    assert output =~ "Local operator identity already exists: #{principal}"
    assert output =~ "Genesis already closed"
    assert File.read!(key_path) == key_bytes
    assert [_root] = root_caps(peer, principal)
    refute_secret_crossed(calls, private_key)

    # Existing identity, missing key file: a clear error, never a second key.
    File.rename!(key_path, key_path <> ".saved")
    assert {:error, calls} = run_init(peer, opts)
    message = errors()
    assert message =~ "#{principal} already exists, but its key file"
    assert message =~ "will not\ngenerate a second key"
    refute File.exists?(key_path)
    assert [:local_human_identity_status] = called_functions(calls)

    # A key file whose public key differs from the registered one is refused.
    {_other_public, other_private} = :crypto.generate_key(:eddsa, :ed25519)

    assert {:ok, _} =
             Arbor.Security.write_key_file(key_path, %{
               agent_id: principal,
               private_key: other_private
             })

    assert {:error, calls} = run_init(peer, opts)
    assert errors() =~ "does not match the registered identity #{principal}"
    assert [:local_human_identity_status] = called_functions(calls)

    # The server refuses it too, even without the CLI's early check.
    assert {:ok, ^principal, other_key, proof} = prepare_registration(key_path)

    assert {:error, :local_human_key_mismatch} =
             peer_call(peer, Arbor.Security, :register_local_human_identity, [
               other_key,
               proof,
               []
             ])

    assert {:ok, %{public_key: ^public_key}} =
             peer_call(peer, Arbor.Security, :local_human_identity_status, [[]])

    # A key file for another principal is refused before anything is sent.
    File.rm!(key_path)
    {_public, foreign_private} = :crypto.generate_key(:eddsa, :ed25519)
    foreign = "human_" <> String.duplicate("f", 40)

    assert {:ok, _} =
             Arbor.Security.write_key_file(key_path, %{
               agent_id: foreign,
               private_key: foreign_private
             })

    assert {:error, calls} = run_init(peer, opts)
    assert errors() =~ "belongs to #{foreign}"
    assert [:local_human_identity_status] = called_functions(calls)

    # The original key file still works.
    File.rm!(key_path)
    File.rename!(key_path <> ".saved", key_path)
    assert {:ok, _calls} = run_init(peer, opts)
    assert infos() =~ "Local operator identity already exists: #{principal}"
  end

  # -- running the task ------------------------------------------------------

  defp run_init(peer, opts) do
    Process.put(:init_test_calls, [])

    remote = fn module, function, args ->
      result = peer_call(peer, module, function, args)
      Process.put(:init_test_calls, [{module, function, args, result} | recorded_calls()])
      result
    end

    result = Init.init_operator(opts, remote)
    calls = Enum.reverse(recorded_calls())

    case result do
      :ok -> {:ok, calls}
      :error -> {:error, calls}
    end
  end

  defp recorded_calls, do: Process.get(:init_test_calls, [])

  defp called_functions(calls), do: Enum.map(calls, fn {_m, function, _a, _r} -> function end)

  defp refute_secret_crossed(calls, private_key) do
    for {_module, function, args, result} <- calls do
      assert :binary.match(:erlang.term_to_binary({args, result}), private_key) == :nomatch,
             "private key material crossed the server boundary in #{function}"
    end
  end

  defp infos, do: drain(:info)
  defp errors, do: drain(:error)

  defp drain(kind) do
    receive do
      {:mix_shell, ^kind, [message]} -> message <> "\n" <> drain(kind)
    after
      0 -> ""
    end
  end

  defp prepare_registration(key_path) do
    {:ok, io_device} = :file.open(String.to_charlist(key_path), [:read, :raw, :binary])

    try do
      Arbor.Security.prepare_key_file_local_human_registration(io_device)
    after
      :file.close(io_device)
    end
  end

  defp root_caps(peer, principal) do
    {:ok, caps} = peer_call(peer, Arbor.Security, :list_capabilities, [principal])
    Enum.filter(caps, &(&1.resource_uri == "arbor://**"))
  end

  defp peer_put_env(peer, key, value), do: SecurityPeer.put_env(peer, key, value)

  defp peer_call(peer, module, function, args),
    do: SecurityPeer.call(peer, module, function, args)

  defp private_dir! do
    {:ok, system_tmp} = SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path = Path.join(system_tmp, "arbor-user-init-#{token}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end
end

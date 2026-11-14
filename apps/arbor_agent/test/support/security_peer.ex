defmodule Arbor.Agent.Test.SecurityPeer do
  @moduledoc false
  # A fresh Arbor "server" on a peer node for CLI-seam tests: this VM plays
  # the Mix task, the peer plays the daemon, and every server call crosses as
  # a serialized term through `:peer.call/5`, as `:rpc` would carry it.
  #
  # The peer runs `:arbor_capabilities` with private, durable authority state
  # and the local-human gate open, as on a dev install, so genesis is open on
  # start. With `agent_runtime: true` it also starts `:arbor_agent` and the
  # minimal agent topology `Lifecycle.create/2` and `start/2` need (the same
  # children `test_helper.exs` adds), without sessions.

  @call_timeout 60_000

  @spec start!(Path.t(), keyword()) :: pid()
  def start!(base_dir, opts \\ []) do
    File.mkdir_p!(base_dir)
    File.chmod!(base_dir, 0o700)
    authority_root = Path.join(base_dir, "authority")
    File.mkdir!(authority_root)
    File.chmod!(authority_root, 0o700)

    peer =
      case :peer.start_link(%{connection: :standard_io, wait_boot: 30_000}) do
        {:ok, peer} -> peer
        {:ok, peer, _node} -> peer
      end

    :ok = call(peer, :code, :add_paths, [:code.get_path()])
    {:ok, _} = call(peer, :application, :ensure_all_started, [:elixir])

    apps =
      if Keyword.get(opts, :agent_runtime, false),
        do: Enum.map(Application.loaded_applications(), &elem(&1, 0)),
        else: [:arbor_kernel, :arbor_capabilities]

    for app <- apps, {key, value} <- Application.get_all_env(app), portable?(value) do
      :ok = call(peer, Application, :put_env, [app, key, value, [persistent: true]])
    end

    kernel_runtime =
      peer
      |> call(Application, :get_env, [:arbor_kernel, :kernel_runtime, []])
      |> Keyword.put(:start_profile, :full)

    :ok =
      call(peer, Application, :put_env, [
        :arbor_kernel,
        :kernel_runtime,
        kernel_runtime,
        [persistent: true]
      ])

    for {key, value} <- [
          start_children: true,
          storage_backend: Arbor.Security.Store.JSONFile,
          authority_state_root: authority_root,
          revocation_ledger_path: Path.join(base_dir, "revocations.json"),
          audit_journal_mode: :durable,
          system_authority_mode: :persistent,
          master_key_path: Path.join(authority_root, "master.key"),
          session_token_secret: Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false),
          distributed_signals: false,
          event_log_adapter: nil,
          allow_local_human_identity: true,
          oidc_adapter: nil,
          oidc: []
        ] do
      put_env(peer, key, value)
    end

    {:ok, _started} = call(peer, Application, :ensure_all_started, [:arbor_capabilities])

    if Keyword.get(opts, :agent_runtime, false), do: start_agent_runtime!(peer)

    peer
  end

  @spec call(pid(), module(), atom(), list()) :: term()
  def call(peer, module, function, args),
    do: :peer.call(peer, module, function, args, @call_timeout)

  @spec put_env(pid(), atom(), term()) :: :ok
  def put_env(peer, key, value) do
    :ok =
      call(peer, Application, :put_env, [
        :arbor_capabilities,
        key,
        value,
        [persistent: true]
      ])
  end

  @spec stop(pid()) :: :ok
  def stop(peer) do
    :peer.stop(peer)
  catch
    _, _ -> :ok
  end

  defp start_agent_runtime!(peer) do
    {:ok, _started} = call(peer, Application, :ensure_all_started, [:arbor_agent])

    for child <- [
          {Registry, keys: :unique, name: Arbor.Agent.ExecutorRegistry},
          {Registry, keys: :unique, name: Arbor.Agent.ReasoningLoopRegistry},
          Arbor.Agent.ProfileAuthorityOwner,
          Arbor.Agent.Registry,
          Arbor.Agent.Supervisor,
          Supervisor.child_spec(
            {Arbor.Persistence.BufferedStore,
             name: :arbor_agent_profiles, backend: nil, write_mode: :sync},
            id: :arbor_agent_profiles
          )
        ] do
      case call(peer, Supervisor, :start_child, [Arbor.Agent.AppSupervisor, child]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        other -> raise "peer agent child #{inspect(child)} failed: #{inspect(other)}"
      end
    end

    %{} = call(peer, Arbor.Agent.Test.RuntimeAdmissionTopology, :start_fixed_production!, [])
    :ok
  end

  # Pids, ports and references from this VM mean nothing on the peer.
  defp portable?(value) when is_pid(value) or is_port(value) or is_reference(value),
    do: false

  defp portable?(value) when is_list(value), do: Enum.all?(value, &portable?/1)

  defp portable?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.all?(&portable?/1)

  defp portable?(%_{} = value), do: value |> Map.from_struct() |> portable?()

  defp portable?(value) when is_map(value),
    do: Enum.all?(value, fn {k, v} -> portable?(k) and portable?(v) end)

  defp portable?(_value), do: true
end

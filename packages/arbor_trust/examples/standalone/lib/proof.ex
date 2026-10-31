defmodule TrustStandaloneConsumer do
  @moduledoc "Independent real Trust consumer with fail-closed, per-attempt qualification gates."
  alias Arbor.Security
  alias Arbor.Security.Config

  @first_party ~w(arbor_capabilities arbor_custody arbor_kernel arbor_oauth arbor_persistence arbor_support arbor_trust)
  @modules [
    Arbor.Trust,
    Arbor.Trust.Application,
    Arbor.Trust.PolicyHost,
    Arbor.Trust.Supervisor,
    Arbor.Trust.Store,
    Arbor.Trust.CapabilityGrantOwner,
    Arbor.Trust.ConfirmationTracker
  ]

  def verify!(opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:trust_standalone_consumer)

    if Keyword.get(opts, :require_no_mix, false) do
      ensure(not Code.ensure_loaded?(Mix), "Mix code was present")
      ensure(:code.lib_dir(:mix) == {:error, :bad_name}, "Mix metadata was present")
    end

    result = GenServer.call(TrustStandaloneConsumer.Provisioner, :verify, 120_000)
    Map.put(result, "mix_available", Code.ensure_loaded?(Mix))
  end

  def verify_owned! do
    ensure(
      self() == Process.whereis(TrustStandaloneConsumer.Provisioner),
      "proof escaped admitted actor process"
    )

    strict_configuration!()
    scenario = System.fetch_env!("TRUST_COLD_SCENARIO")

    result =
      case scenario do
        "full" -> full!()
        "activation_only" -> activation!()
        "runtime_unavailable" -> runtime_unavailable!()
        "profile_sync_unavailable" -> profile_sync_unavailable!()
        _ -> raise "unadmitted Trust cold scenario"
      end

    closure!(scenario)

    Map.merge(result, %{
      "scenario" => scenario,
      "first_party" => @first_party,
      "profile_storage_claim" => "explicit memory; no Trust durable restart claim",
      "profile_sync_claim" => "explicit single-node nil transport; no distributed sync claim",
      "code_paths" =>
        Map.new(@modules, fn module ->
          ensure(
            :application.get_application(module) == {:ok, :arbor_trust},
            "wrong Trust module owner"
          )

          {Atom.to_string(module), List.to_string(:code.which(module))}
        end)
    })
  end

  defp full! do
    context = TrustStandaloneConsumer.CoreContext.context!()
    {:ok, _} = Application.ensure_all_started(:arbor_trust)
    # The real owner is ready only after its public continuation; no fixture process substitutes.
    await(fn ->
      state = :sys.get_state(Arbor.Trust.CapabilitySync)
      if state.subscribed == true, do: :ok, else: nil
    end)

    result = ComposedTrustProof.verify!(context)
    supervisor = Process.whereis(Arbor.Trust.Supervisor)

    ensure(
      Arbor.Trust.start_link([]) == {:error, {:already_started, supervisor}},
      "public full lifecycle started another canonical tree"
    )

    ensure(Arbor.Trust.healthy?(), "real full application is not healthy")
    result
  end

  defp activation! do
    Application.put_env(:arbor_trust, :runtime, start_profile: :activation_only)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)
    root = Process.whereis(Arbor.Trust.ApplicationSupervisor)
    host = Process.whereis(Arbor.Trust.PolicyHost)
    ensure(is_pid(root) and is_pid(host), "activation omitted canonical root or PolicyHost")

    ensure(
      :application.get_application(root) == {:ok, :arbor_trust} and
        :application.get_application(host) == {:ok, :arbor_trust},
      "activation reparented authority"
    )

    ensure(
      Enum.map(Supervisor.which_children(root), &elem(&1, 0)) == [Arbor.Trust.PolicyHost],
      "activation started providers or mutable consumers"
    )

    for name <- [
          Arbor.Trust.Supervisor,
          Arbor.Trust.ProviderGate,
          Arbor.Trust.Manager,
          Arbor.Trust.Store,
          Arbor.Trust.CapabilityGrantOwner,
          Arbor.Trust.ConfirmationTracker
        ] do
      ensure(Process.whereis(name) == nil, "activation started a later authority child")
    end

    ensure(
      Arbor.Trust.start_link([]) == {:ok, host},
      "public activation lifecycle did not return actual PolicyHost"
    )

    ensure(Arbor.Trust.healthy?(), "real activation application is not healthy")

    ensure(
      Arbor.Trust.effective_mode("agent_unknown", "arbor://shell/exec/git") == :ask,
      "activation failed to retain conservative unknown-principal ceiling"
    )

    %{
      "checks" => [
        "actual canonical activation-only PolicyHost",
        "no provider/consumer subtree",
        "same public lifecycle owner and conservative frozen ceiling"
      ]
    }
  end

  defp runtime_unavailable! do
    Application.put_env(:arbor_trust, :runtime_host, TrustStandaloneConsumer.UnavailableRuntime)

    ensure(
      match?(
        {:error,
         {:arbor_trust, {:runtime_host_unavailable, {Arbor.Trust.Application, :start, _}}}},
        Application.ensure_all_started(:arbor_trust)
      ),
      "configured unavailable runtime did not fail actual startup"
    )

    absent_tree!()
    %{"checks" => ["configured runtime failure denies before PolicyHost; no nil-host fallback"]}
  end

  defp profile_sync_unavailable! do
    Application.put_env(
      :arbor_trust,
      :profile_sync_transport,
      TrustStandaloneConsumer.UnavailableProfileSync
    )

    result = Application.ensure_all_started(:arbor_trust)

    ensure(
      match?({:error, _}, result) and inspect(result) =~ "profile_sync_unavailable",
      "configured sync failure did not refuse real Store startup"
    )

    absent_tree!()

    ensure(
      :ets.whereis(:trust_profile_cache) == :undefined,
      "refused sync startup claimed profile cache"
    )

    %{"checks" => ["configured sync failure refuses real Store startup and cache ownership"]}
  end

  defp absent_tree! do
    for name <- [
          Arbor.Trust.ApplicationSupervisor,
          Arbor.Trust.PolicyHost,
          Arbor.Trust.Supervisor,
          Arbor.Trust.Store,
          Arbor.Trust.CapabilityGrantOwner,
          Arbor.Trust.ConfirmationTracker
        ] do
      ensure(Process.whereis(name) == nil, "refused startup left an active authority subtree")
    end
  end

  defp strict_configuration! do
    {:ok, [[cookie]]} = :init.get_argument(:setcookie)
    expected = System.fetch_env!("PAIRED_COOKIE_SHA256")

    ensure(
      Base.encode16(:crypto.hash(:sha256, List.to_string(cookie)), case: :lower) == expected,
      "VM did not receive exactly the pinned synthetic cookie"
    )

    ensure(not Node.alive?(), "leaf unexpectedly opened distribution")
    ensure(Config.identity_verification_enabled?(), "identity verification disabled")
    ensure(Config.capability_signing_required?(), "capability signing disabled")
    ensure(Config.delegation_chain_verification_enabled?(), "delegation verification disabled")
    ensure(Config.constraint_enforcement_enabled?(), "constraint enforcement disabled")
    ensure(Config.invocation_audit_mode() == :required, "required audit disabled")

    ensure(
      Application.fetch_env!(:arbor_capabilities, :strict_identity_mode) == true,
      "strict identity disabled"
    )

    ensure(
      Application.fetch_env!(:arbor_trust, :policy_enforcer_enabled) == true,
      "Trust enforcer disabled"
    )

    ensure(
      Application.fetch_env!(:arbor_trust, :approval_guard_enabled) == true,
      "Trust approval guard disabled"
    )

    ensure(
      Application.fetch_env!(:arbor_trust, :profile_store) == [mode: :memory],
      "leaf changed profile persistence claim"
    )

    ensure(
      Application.fetch_env!(:arbor_trust, :runtime_host) == nil,
      "leaf inherited a product runtime host"
    )

    ensure(
      Application.fetch_env!(:arbor_trust, :profile_sync_transport) == nil,
      "leaf inherited a distributed transport"
    )

    ensure(
      Arbor.Trust.Config.pubsub() == TrustStandaloneConsumer.PubSub,
      "leaf inherited a product PubSub"
    )

    root = System.fetch_env!("CAPABILITIES_COLD_STATE_ROOT")

    ensure(
      Config.authority_root() == {:ok, Path.join(root, "authority")},
      "authority root fell back"
    )

    ensure(
      Config.revocation_ledger_path() ==
        {:ok, Path.join(root, "independent-revocations/capability_revocations.v1.json")},
      "revocation path changed"
    )

    ensure(not Security.oidc_enabled?(), "first-install leaf unexpectedly configured OIDC")

    ensure(
      not function_exported?(Security, :register_identity_fixture, 1),
      "test identity fixture leaked"
    )

    ensure(
      not function_exported?(Arbor.Trust, :restart_capability_grant_owner_fixture, 0),
      "Trust test fixture leaked"
    )

    for module <- [
          Arbor.KernelRuntime,
          Arbor.Common,
          Arbor.Signals,
          Arbor.Capabilities.OIDC,
          Arbor.Persistence,
          Arbor.Persistence.Repo,
          Ecto,
          Arbor.Historian,
          Arbor.Trust.Host.Runtime
        ] do
      ensure(
        not Code.ensure_loaded?(module),
        "forbidden product/SQL/transport module was available"
      )
    end
  end

  defp closure!(scenario) do
    expected_started =
      if scenario in ["runtime_unavailable", "profile_sync_unavailable"],
        do: List.delete(@first_party, "arbor_trust"),
        else: @first_party

    loaded = first_party(Application.loaded_applications())
    started = first_party(Application.started_applications())
    ensure(loaded == @first_party, "unexpected loaded first-party closure")
    ensure(started == expected_started, "unexpected started first-party closure")

    compiled =
      :code.get_path()
      |> Enum.map(&Path.basename(Path.dirname(List.to_string(&1))))
      |> Enum.filter(&String.starts_with?(&1, "arbor_"))
      |> Enum.map(&String.replace(&1, ~r/-\d.*$/, ""))
      |> Enum.uniq()
      |> Enum.sort()

    ensure(compiled == @first_party, "unexpected compiled first-party closure")

    for app <- [
          :arbor_trust_host,
          :arbor_historian_host,
          :arbor_historian,
          :arbor_signals,
          :arbor_security,
          :arbor_kernel_runtime,
          :arbor_persistence_host,
          :arbor_persistence_sql,
          :arbor_capabilities_oidc,
          :ecto,
          :ecto_sql,
          :postgrex,
          :exqlite
        ] do
      ensure(
        :code.lib_dir(app) == {:error, :bad_name},
        "forbidden application metadata/code path was present"
      )
    end

    for app <- [:req, :finch, :mint] do
      ensure(
        not List.keymember?(Application.started_applications(), app, 0),
        "HTTP provider unexpectedly started"
      )
    end
  end

  defp first_party(apps),
    do:
      apps
      |> Enum.map(fn {app, _, _} -> Atom.to_string(app) end)
      |> Enum.filter(&String.starts_with?(&1, "arbor_"))
      |> Enum.sort()

  defp await(fun), do: await(fun, System.monotonic_time(:millisecond) + 10_000)

  defp await(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("actual private PubSub subscription unavailable")

        receive do
        after
          10 -> await(fun, deadline)
        end

      value ->
        value
    end
  end

  defp ensure(true, _), do: :ok
  defp ensure(false, label), do: raise("Trust leaf qualification failed: " <> label)
end

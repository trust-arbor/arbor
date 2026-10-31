defmodule ComposedTrustProof do
  @moduledoc "Real canonical Trust proof shared by leaf and composed private consumers. No production gate is replaced."
  alias Arbor.Security
  alias Arbor.Trust
  alias Arbor.Trust.{CapabilityGrantOwner, PolicyEnforcer}

  def approval_owner_child_spec, do: {ComposedTrustProof.ApprovalOwner, []}

  # Must run synchronously in the existing actor-authority owner's PID.
  # :write creates the acknowledged profile and exact public evidence file.
  # Other phases read existing persisted state and never silently reseed it.
  def verify!(
        %{
          operator_id: operator,
          operator_authority: actor,
          agent_id: agent,
          agent_authority: agent_authority,
          pubsub: pubsub
        } = context
      ) do
    :ok = Security.validate_signing_authority_owner(actor, self(), operator)
    :ok = Security.validate_signing_authority_owner(agent_authority, self(), agent)

    ensure(
      Trust.Config.pubsub() == pubsub and not is_nil(pubsub),
      "explicit private PubSub changed"
    )

    owners!()
    phase = Map.get(context, :phase, :write)
    result = if phase == :write, do: write!(context), else: recover!(context)

    Map.merge(result, %{
      "phase" => Atom.to_string(phase),
      "canonical_application" => "arbor_trust",
      "claims" => %{
        "freeze" => "state and observe-only delivery; no automatic revoke claim",
        "revocation" => "explicit policy block plus caller-owned actor sync"
      }
    })
  end

  defp write!(context) do
    %{
      operator_authority: actor,
      agent_id: agent,
      agent_authority: agent_authority,
      pubsub: pubsub
    } = context

    resource = "arbor://memory/read/" <> agent <> "/trust-cold"
    session = "trust-cold-session-" <> agent
    ensure(not File.exists?(evidence_file()), "write reused prior Trust evidence")

    {:ok, profile} =
      Trust.ensure_trust_profile(agent, baseline: :block, rules: %{resource => :allow})

    ensure(profile.rules[resource] == :allow, "profile acknowledgement changed requested policy")

    ensure(
      Trust.effective_mode(agent, resource) == :allow,
      "real frozen policy host did not admit explicit read rule"
    )

    ensure(
      match?(
        {:error, {:unsafe_prefix, _}},
        Trust.set_rule(agent, "arbor://memory/read/../escape", :auto)
      ),
      "unsafe prefix admitted"
    )

    {:ok, unchanged} = Trust.get_trust_profile(agent)
    ensure(unchanged.rules == profile.rules, "unsafe rule changed profile")

    ensure(
      Trust.effective_mode(agent, "arbor://shell/exec/git", security_ceilings: %{}) != :auto,
      "caller options relaxed the host ceiling"
    )

    # A name-only request cannot spend ambient server authority.
    ensure(
      PolicyEnforcer.sync_capabilities(agent) == {:error, :capability_mutation_unauthorized},
      "sync accepted absent actor authority"
    )

    status =
      await(fn ->
        status = Trust.capability_grant_owner_status()
        if is_binary(status.principal_id), do: status, else: nil
      end)

    ensure(status.state in [:dormant, :ready], "grant owner did not finish its real continuation")

    if status.state == :dormant do
      {:ok, _cap} =
        Security.grant(
          principal: status.principal_id,
          resource: CapabilityGrantOwner.required_capability_uri(),
          delegation_depth: 0,
          actor_authority: actor,
          metadata: %{source: :cold_operator_provisioning}
        )

      supervisor = Process.whereis(Arbor.Trust.Supervisor)
      :ok = Supervisor.terminate_child(supervisor, CapabilityGrantOwner)
      {:ok, _pid} = Supervisor.restart_child(supervisor, CapabilityGrantOwner)
    end

    ready =
      await(fn ->
        status = Trust.capability_grant_owner_status()
        if status.state == :ready, do: status, else: nil
      end)

    ensure(
      ready.principal_id == status.principal_id,
      "provisioning changed the canonical named principal"
    )

    ensure(
      Security.signing_key_status(ready.principal_id) == {:ok, :available},
      "ready owner lost encrypted key"
    )

    ensure(
      Security.load_signing_key(ready.principal_id) == {:error, :unauthorized},
      "raw-key API disclosed owner material"
    )

    owners!()
    custody!()

    ensure(
      match?(
        {:error, _},
        Security.build_stored_signing_authority_acquisition_proof(
          ready.principal_id,
          :trust_capability_grant,
          self(),
          CapabilityGrantOwner
        )
      ),
      "wrong PID acquired the grant owner's signing purpose"
    )

    {:ok, grant_payload} = Trust.build_capability_grant_request(agent, resource, session)
    {:ok, wrong_signer} = Security.sign_with_authority(actor, grant_payload)

    ensure(
      CapabilityGrantOwner.request(wrong_signer) == {:error, :capability_grant_request_denied},
      "grant owner accepted a signer other than the target"
    )

    {:ok, request} = Security.sign_with_authority(agent_authority, grant_payload)
    {:ok, capability} = CapabilityGrantOwner.request(request)

    ensure(
      capability.principal_id == agent and capability.resource_uri == resource and
        capability.session_id == session and is_binary(capability.issuer_signature),
      "real JIT grant lost principal, resource, session or signature"
    )

    ensure(
      CapabilityGrantOwner.request(request) == {:error, :capability_grant_request_replayed},
      "one-use JIT request replay admitted"
    )

    {:ok, signed} = Security.sign_with_authority(agent_authority, resource)

    ensure(
      Trust.authorize(agent, resource, :read,
        session_id: session,
        signed_request: signed,
        expected_resource: resource
      ) == {:ok, :authorized},
      "real signed Trust admission failed"
    )

    # PubSub lifecycle messages are real, but current Main makes them observe-only.
    :ok = Phoenix.PubSub.subscribe(pubsub, "trust:events")
    before_ids = capability_ids!(agent)
    before_mode = Trust.effective_mode(agent, resource)
    :ok = Trust.freeze_trust(agent, :cold_qualification)

    receive do
      {:trust_event, ^agent, :trust_frozen, %{reason: :cold_qualification}} -> :ok
    after
      5_000 -> raise "missing real freeze PubSub delivery"
    end

    {:ok, frozen} = Trust.get_trust_profile(agent)
    ensure(frozen.frozen == true, "freeze write was not acknowledged")

    ensure(
      Trust.effective_mode(agent, resource) == before_mode,
      "current Main freeze behavior changed; this draft must not assume new enforcement"
    )

    # Status is a public OTP mailbox barrier behind the event, not a timing sleep.
    _status = :sys.get_status(Arbor.Trust.CapabilitySync)

    ensure(
      capability_ids!(agent) == before_ids,
      "unauthenticated lifecycle observation mutated capabilities"
    )

    :ok = Trust.unfreeze_trust(agent)

    receive do
      {:trust_event, ^agent, :trust_unfrozen, _} -> :ok
    after
      5_000 -> raise "missing real unfreeze PubSub delivery"
    end

    {:ok, thawed} = Trust.get_trust_profile(agent)
    ensure(thawed.frozen == false, "unfreeze write was not acknowledged")

    approval = approval!(context)
    {:ok, blocked} = Trust.set_rule(agent, resource, :block)
    ensure(blocked.rules[resource] == :block, "block rule was not acknowledged")
    :ok = PolicyEnforcer.sync_capabilities(agent, actor_authority: actor)

    ensure(
      not Enum.member?(capability_ids!(agent), capability.id),
      "explicit actor sync did not revoke stale JIT cap"
    )

    ensure(Security.identity_status(agent) == {:ok, :active}, "revocation negative lost identity")

    ensure(
      Security.signing_key_status(agent) == {:ok, :available},
      "revocation negative lost key"
    )

    {:ok, denied_request} = Security.sign_with_authority(agent_authority, resource)

    ensure(
      match?(
        {:error, _},
        Trust.authorize(agent, resource, :read,
          session_id: session,
          signed_request: denied_request,
          expected_resource: resource
        )
      ),
      "blocked policy still authorized"
    )

    :ok = Phoenix.PubSub.unsubscribe(pubsub, "trust:events")

    evidence = %{
      "agent_id" => agent,
      "resource" => resource,
      "jit_capability_id" => capability.id,
      "grant_owner_principal" => ready.principal_id,
      "baseline" => Atom.to_string(blocked.baseline),
      "rules" => Map.new(blocked.rules, fn {key, value} -> {key, Atom.to_string(value)} end),
      "approval_request_id" => approval["request_id"],
      "frozen" => false
    }

    write_public_evidence!(evidence)

    %{
      "checks" => [
        "acknowledged real profile and immutable policy ceiling",
        "canonical supervised grant-owner provisioning and inaccessible private custody",
        "target-signed JIT grant, wrong-signer denial and one-use replay denial",
        "real strict signed Trust admission",
        "actual freeze/unfreeze state and observe-only private PubSub delivery",
        "owner-read human approval and canonical one-use receipt",
        "explicit block plus actor-owned sync revocation with active identity and key"
      ],
      "public_state" => evidence
    }
  end

  defp recover!(%{agent_id: agent} = context) do
    saved = evidence_file() |> File.read!() |> Jason.decode!()
    ensure(saved["agent_id"] == agent, "persistent Trust agent identity changed")
    {:ok, profile} = Trust.get_trust_profile(agent)

    ensure(
      Atom.to_string(profile.baseline) == saved["baseline"] and profile.frozen == saved["frozen"],
      "cold profile baseline/frozen state changed"
    )

    ensure(
      Map.new(profile.rules, fn {key, value} -> {key, Atom.to_string(value)} end) ==
        saved["rules"],
      "cold authoritative profile rules were not recovered"
    )

    ensure(
      Trust.effective_mode(agent, saved["resource"]) == :block,
      "persisted explicit policy block disappeared"
    )

    ready =
      await(fn ->
        status = Trust.capability_grant_owner_status()
        if status.state == :ready, do: status, else: nil
      end)

    ensure(
      ready.principal_id == saved["grant_owner_principal"],
      "canonical grant-owner identity changed across VM restart"
    )

    ensure(
      not Enum.member?(capability_ids!(agent), saved["jit_capability_id"]),
      "revoked JIT capability reappeared"
    )

    ensure(Security.identity_status(agent) == {:ok, :active}, "persistent principal missing")
    ensure(Security.signing_key_status(agent) == {:ok, :available}, "persistent key missing")
    {:ok, signed} = Security.sign_with_authority(context.agent_authority, saved["resource"])

    ensure(
      match?(
        {:error, _},
        Trust.authorize(agent, saved["resource"], :read,
          signed_request: signed,
          expected_resource: saved["resource"]
        )
      ),
      "recovered blocked policy admitted"
    )

    custody!()

    %{
      "checks" => [
        "cold acknowledged profile/rules readback",
        "same persistent canonical grant owner",
        "revoked JIT authority stays absent with usable identity/key"
      ],
      "public_state" => saved
    }
  end

  defp approval!(%{
         operator_id: human,
         operator_authority: actor,
         agent_id: agent,
         agent_authority: agent_authority
       }) do
    resource = "arbor://memory/write/" <> agent <> "/approved-receipt"
    request_id = "trust-cold-approval-" <> agent
    expected = %{agent_id: agent, principal_id: agent, resource_uri: resource, decision: :approve}
    arguments = %{"operation" => "private-cold-proof", "target" => agent}
    :ok = ComposedTrustProof.ApprovalOwner.open(request_id, expected)

    ensure(
      Trust.issue_approval_receipt(:interaction, request_id, expected, arguments) ==
        {:error, :approval_evidence_unavailable},
      "unanswered approval minted a receipt"
    )

    ensure(
      ComposedTrustProof.ApprovalOwner.answer(request_id, human, "unproved-session") ==
        {:error, :approval_answer_required},
      "approval owner trusted an unproved responder"
    )

    {:ok, token} = Security.issue_human_session_token(human, actor)
    :ok = ComposedTrustProof.ApprovalOwner.answer(request_id, human, token)
    {:ok, :recorded} = Trust.record_approval_answer(:interaction, request_id, expected)
    {:ok, :duplicate} = Trust.record_approval_answer(:interaction, request_id, expected)

    ensure(
      match?(
        {:error, _},
        Trust.record_approval_answer(:interaction, request_id, %{
          expected
          | resource_uri: resource <> "/other"
        })
      ),
      "caller rewrote owning approval scope"
    )

    ensure(
      Security.claim_approval_receipt_issuer() == {:error, :unauthorized_approval_issuer},
      "wrong PID claimed canonical ConfirmationTracker custody"
    )

    {:ok, receipt} = Trust.issue_approval_receipt(:interaction, request_id, expected, arguments)

    {:ok, _cap} =
      Security.grant(
        principal: agent,
        resource: resource,
        constraints: %{requires_approval: true},
        actor_authority: actor
      )

    {:ok, digest} = Security.approval_argument_digest(arguments)
    {:ok, unapproved} = Security.sign_with_authority(agent_authority, resource)

    ensure(
      Security.authorize(agent, resource, :execute,
        signed_request: unapproved,
        expected_resource: resource
      ) != {:ok, :authorized},
      "approval-constrained invocation admitted without receipt"
    )

    {:ok, wrong_digest} = Security.approval_argument_digest(%{"operation" => "different"})
    {:ok, wrong_arguments} = Security.sign_with_authority(agent_authority, resource)

    ensure(
      Security.authorize(agent, resource, :execute,
        signed_request: wrong_arguments,
        expected_resource: resource,
        approved_invocation: receipt,
        argument_digest: wrong_digest
      ) ==
        {:error, :invalid_approval_receipt},
      "receipt accepted different invocation arguments"
    )

    {:ok, signed} = Security.sign_with_authority(agent_authority, resource)

    ensure(
      Security.authorize(agent, resource, :execute,
        signed_request: signed,
        expected_resource: resource,
        approved_invocation: receipt,
        argument_digest: digest
      ) == {:ok, :authorized},
      "canonical owner-issued exact approval receipt failed real admission"
    )

    {:ok, replay} = Security.sign_with_authority(agent_authority, resource)

    ensure(
      Security.authorize(agent, resource, :execute,
        signed_request: replay,
        expected_resource: resource,
        approved_invocation: receipt,
        argument_digest: digest
      ) ==
        {:error, :invalid_approval_receipt},
      "one-use approval receipt replay admitted"
    )

    ensure(
      Trust.accept_graduation(agent, "arbor://memory/read") ==
        {:error, :human_acceptance_required},
      "retired unverified graduation path admitted"
    )

    %{"request_id" => request_id}
  end

  def owners! do
    application_root = Process.whereis(Arbor.Trust.ApplicationSupervisor)
    ensure(is_pid(application_root), "canonical Trust application root absent")

    ensure(
      :application.get_application(application_root) == {:ok, :arbor_trust},
      "Trust root owned by another app"
    )

    supervisor = Process.whereis(Arbor.Trust.Supervisor)

    ensure(
      Enum.any?(Supervisor.which_children(application_root), fn
        {Arbor.Trust.Supervisor, ^supervisor, :supervisor, _} -> true
        _ -> false
      end),
      "Trust supervisor is not the actual canonical application child"
    )

    for module <- [
          Arbor.Trust.PolicyHost,
          Arbor.Trust.ConfirmationTracker,
          CapabilityGrantOwner,
          Arbor.Trust.Store,
          Arbor.Trust.Manager,
          Arbor.Trust.CapabilitySync
        ] do
      pid = Process.whereis(module)

      ensure(
        is_pid(pid) and :application.get_application(pid) == {:ok, :arbor_trust},
        "wrong canonical Trust process owner"
      )

      ensure(
        Application.get_application(module) == :arbor_trust,
        "wrong canonical Trust BEAM owner"
      )

      parent = if module == Arbor.Trust.PolicyHost, do: application_root, else: supervisor

      ensure(
        Enum.any?(Supervisor.which_children(parent), fn
          {^module, ^pid, _, _} -> true
          _ -> false
        end),
        "canonical authority owner was reparented"
      )
    end

    :ok
  end

  defp custody! do
    owner = Process.whereis(CapabilityGrantOwner)

    ensure(
      not authority_in?(:sys.get_state(owner)),
      "grant owner's public state exposed signing authority"
    )

    ensure(
      not authority_in?(:sys.get_status(owner)),
      "grant owner's status exposed signing authority"
    )

    table = Arbor.Trust.CapabilityGrantOwner.Custody

    ensure(
      :ets.info(table, :owner) == owner and :ets.info(table, :protection) == :private,
      "grant-owner custody no longer belongs privately to actual owner"
    )

    inaccessible =
      try do
        :ets.lookup(table, :arbor_trust_capability_grant_owner_custody_v1)
        false
      rescue
        ArgumentError -> true
      end

    ensure(inaccessible, "non-owner could read grant custody")
    :ok
  end

  defp authority_in?(%Arbor.Contracts.Security.SigningAuthority{}), do: true

  defp authority_in?(map) when is_map(map),
    do: Enum.any?(map, fn {key, value} -> authority_in?(key) or authority_in?(value) end)

  defp authority_in?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> authority_in?()
  defp authority_in?(list) when is_list(list), do: Enum.any?(list, &authority_in?/1)
  defp authority_in?(_), do: false

  defp capability_ids!(agent) do
    {:ok, caps} = Security.list_capabilities(agent)
    Enum.map(caps, & &1.id) |> Enum.sort()
  end

  defp write_public_evidence!(evidence) do
    path = evidence_file()
    {:ok, file} = :file.open(String.to_charlist(path), [:write, :exclusive, :binary, :raw])

    try do
      :ok = :file.write(file, Jason.encode!(evidence))
      :ok = :file.sync(file)
    after
      :file.close(file)
    end

    File.chmod!(path, 0o600)
  end

  defp evidence_file,
    do: Path.join(System.fetch_env!("PAIRED_STATE_ROOT"), "trust-public-evidence.json")

  defp await(fun), do: await_until(fun, System.monotonic_time(:millisecond) + 10_000)

  defp await_until(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("bounded Trust readiness timeout")

        receive do
        after
          10 -> await_until(fun, deadline)
        end

      value ->
        value
    end
  end

  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("Trust qualification failed: " <> label)
end

defmodule ComposedTrustProof.ApprovalOwner do
  @moduledoc "Consumer-owned pending request authority. Winning transition requires actual current Security human/session approval authority."
  use GenServer
  @behaviour Arbor.Trust.Contracts.ApprovalEvidenceProvider
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl GenServer
  def init(_), do: {:ok, %{}}
  def open(id, expected), do: GenServer.call(__MODULE__, {:open, id, expected})
  def answer(id, human, token), do: GenServer.call(__MODULE__, {:answer, id, human, token})
  @impl Arbor.Trust.Contracts.ApprovalEvidenceProvider
  def answered_approval(source, id), do: GenServer.call(__MODULE__, {:read, source, id})
  @impl GenServer
  def handle_call({:open, id, expected}, _from, rows) when map_size(rows) < 32 do
    if Map.has_key?(rows, id),
      do: {:reply, {:error, :already_open}, rows},
      else: {:reply, :ok, Map.put(rows, id, %{expected: expected, answer: nil})}
  end

  def handle_call({:answer, id, human, token}, _from, rows) do
    with {:ok, %{expected: expected, answer: nil} = row} <- Map.fetch(rows, id),
         :ok <- Arbor.Security.authorize_approval_answer(human, "arbor://approval/answer", token) do
      record =
        Map.merge(expected, %{source: :interaction, request_id: id, verified_human_id: human})

      {:reply, :ok, Map.put(rows, id, %{row | answer: record})}
    else
      _ -> {:reply, {:error, :approval_answer_required}, rows}
    end
  end

  def handle_call({:read, :interaction, id}, _from, rows) do
    case Map.get(rows, id) do
      %{answer: answer} when is_map(answer) -> {:reply, {:ok, answer}, rows}
      _ -> {:reply, {:error, :approval_evidence_unavailable}, rows}
    end
  end

  def handle_call(_request, _from, rows),
    do: {:reply, {:error, :approval_evidence_unavailable}, rows}
end

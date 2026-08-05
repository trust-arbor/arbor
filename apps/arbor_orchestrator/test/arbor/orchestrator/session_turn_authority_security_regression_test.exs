defmodule Arbor.Orchestrator.SessionTurnAuthoritySecurityRegressionTest do
  @moduledoc """
  Security regression: receipt-authenticated Session ingress (VP-05D2A1P2)
  and Engine final-outcome admission (VP-05D2A1P2R2).

  Security prerequisite for VOICE-17 (planned); does not un-plan the normative
  VOICE-17 statement. Self-contained — no shared new helper modules.
  """

  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag voice_id: "VOICE-17"
  @moduletag spec: "VOICE-17"

  alias Arbor.Contracts.Security.DeliveryReceipt
  alias Arbor.Comms
  alias Arbor.Comms.EngagementStore
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Session.TurnAuthority
  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.Identifiers
  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.Session.Builders
  alias Arbor.Security
  alias Arbor.Security.SessionToken
  alias Arbor.Signals

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_comms)
    ensure_signals_stack!()

    backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    for {name, collection} <- [
          {:arbor_security_capabilities, "capabilities"},
          {:arbor_security_identities, "identities"},
          {:arbor_security_signing_keys, "signing_keys"}
        ] do
      child =
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: name, backend: backend, write_mode: :sync, collection: collection},
          id: name
        )

      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []},
          {Arbor.Security.DeliveryReceiptBroker, []}
        ] do
      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    :ok
  end

  setup do
    prev = %{
      identity_verification: Application.get_env(:arbor_security, :identity_verification),
      strict: Application.get_env(:arbor_security, :strict_identity_mode),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      uri: Application.get_env(:arbor_security, :uri_registry_enforcement),
      secret: Application.get_env(:arbor_security, :session_token_secret)
    }

    Application.put_env(:arbor_security, :identity_verification, true)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)

    Application.put_env(
      :arbor_security,
      :session_token_secret,
      "vp05d2a1p2-test-secret-#{System.unique_integer([:positive])}"
    )

    on_exit(fn ->
      restore(:identity_verification, prev.identity_verification)
      restore(:strict_identity_mode, prev.strict)
      restore(:capability_signing_required, prev.signing)
      restore(:reflex_checking_enabled, prev.reflex)
      restore(:uri_registry_enforcement, prev.uri)
      restore(:session_token_secret, prev.secret)
    end)

    agent = register_active_agent!()
    agent_id = agent.agent_id
    human_id = register_active_human!()
    resource = "arbor://chat/agent/#{agent_id}"
    grant!(human_id, resource)

    %{
      agent_id: agent_id,
      agent_signer: agent.signer,
      human_id: human_id,
      resource: resource
    }
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore(key, value), do: Application.put_env(:arbor_security, key, value)

  defp register_active_agent! do
    assert {:ok, identity} = Identity.generate(name: "VP05D2A1P2 session agent")
    assert :ok = Security.register_identity(Identity.public_only(identity))

    on_exit(fn ->
      _ = Security.deregister_identity(identity.agent_id)
    end)

    %{
      agent_id: identity.agent_id,
      signer: fn resource ->
        SignedRequest.sign(resource, identity.agent_id, identity.private_key)
      end
    }
  end

  defp register_active_human! do
    unique = System.unique_integer([:positive, :monotonic])
    issuer = "https://oidc-test.arbor.local/vp05d2a1p2/#{unique}"
    subject = "subject-#{unique}"
    client_id = "arbor-test-client"
    kid = "test-key-#{unique}"

    private_jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, private_map} = JOSE.JWK.to_map(private_jwk)
    {_, public_map} = JOSE.JWK.to_public_map(private_jwk)
    public_map = Map.merge(public_map, %{"alg" => "ES256", "kid" => kid})
    signer = Joken.Signer.create("ES256", private_map, %{"kid" => kid})

    claims = %{
      "iss" => issuer,
      "sub" => subject,
      "aud" => client_id,
      "exp" => System.os_time(:second) + 3_600,
      "iat" => System.os_time(:second),
      "email" => "operator-#{unique}@example.test",
      "name" => "VP05D2A1P2 OIDC Human"
    }

    {:ok, id_token} = Joken.Signer.sign(claims, signer)

    table = :arbor_oidc_jwks_cache

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    end

    true =
      :ets.insert(
        table,
        {issuer, %{"keys" => [public_map]}, System.monotonic_time(:millisecond) + 60_000}
      )

    {:ok, identity} = Arbor.Contracts.Security.Identity.generate(name: claims["name"])

    human_id =
      "human_" <>
        String.slice(
          Base.encode16(:crypto.hash(:sha256, "#{issuer}:#{subject}"), case: :lower),
          0,
          40
        )

    human_identity = %{
      identity
      | agent_id: human_id,
        metadata: %{
          "identity_type" => "human",
          "oidc_issuer" => issuer,
          "oidc_sub" => subject
        }
    }

    assert :ok =
             Security.register_oidc_identity(human_identity, id_token, %{
               issuer: issuer,
               client_id: client_id
             })

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table, issuer)
      _ = Security.deregister_identity(human_id)
    end)

    human_id
  end

  defp grant!(principal, resource) do
    assert {:ok, cap} = Security.grant(principal: principal, resource: resource)

    on_exit(fn ->
      _ = Security.revoke(cap.id)
    end)

    cap
  end

  defp put_orchestrator_cap!(agent_id) do
    assert {:ok, cap} =
             Arbor.Contracts.Security.Capability.new(
               resource_uri: "arbor://orchestrator/execute/**",
               principal_id: agent_id,
               delegation_depth: 0,
               constraints: %{},
               metadata: %{test: true}
             )

    Arbor.Security.CapabilityStore.put(cap)

    on_exit(fn ->
      _ = Arbor.Security.CapabilityStore.revoke(cap.id)
    end)

    cap
  end

  defp issue_receipt!(human_id, resource, action \\ :chat) do
    assert {:ok, token} = SessionToken.generate(human_id)

    assert {:ok, receipt} =
             Security.authorize_and_issue_delivery_receipt(human_id, resource, action,
               session_token: token
             )

    receipt
  end

  defp user_message!(human_id, content \\ "hello authenticated") do
    UserMessage.from_voice(content, sender_id: human_id)
  end

  defp collision_resistant_session_id do
    "session_vp05r2_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp session_logs_root(session_id) do
    Path.join([System.tmp_dir!(), "arbor_sessions", session_id])
  end

  defp track_session_log_root!(session_id) when is_binary(session_id) do
    root = session_logs_root(session_id)

    on_exit(fn ->
      _ = File.rm_rf(root)
    end)

    root
  end

  defp session_state(agent_id, overrides \\ []) do
    session_id =
      Keyword.get_lazy(overrides, :session_id, fn -> collision_resistant_session_id() end)

    track_session_log_root!(session_id)

    base = %Session{
      session_id: session_id,
      agent_id: agent_id,
      phase: :idle,
      turn_count: 0,
      messages: [],
      turn_in_flight: false,
      turn_from: nil,
      turn_caller_ref: nil,
      turn_task_ref: nil,
      turn_task_pid: nil,
      turn_user_message: nil,
      streaming_buffer: nil,
      turn_queue: [],
      cancelled_task_ids: %{},
      cancelled_task_id_order: [],
      config: %{},
      session_state: nil,
      behavior: nil,
      steer_froms: [],
      execution_mode: :session
    }

    overrides
    |> Keyword.delete(:session_id)
    |> Enum.reduce(Map.put(base, :turn_authority, nil), fn {key, value}, state ->
      Map.put(state, key, value)
    end)
  end

  defp authority!(human_id) do
    assert {:ok, auth} =
             TurnAuthority.new(
               turn_id: Identifiers.generate_id("turn_"),
               authenticated_principal_id: human_id,
               disclosure_capability_id: nil
             )

    auth
  end

  # Detect receipts or raw authority/receipt material in a term tree.
  # `allow_turn_authority?: true` permits process-local TurnAuthority structs
  # (Session state/queue) while still rejecting raw id/token bytes when listed.
  # Binary matching uses :binary.match so raw 32-byte bearers (non-UTF-8) work.
  defp term_contains_forbidden?(term, forbidden_binaries, opts) do
    allow_ta? = Keyword.get(opts, :allow_turn_authority?, false)
    inspected = inspect(term, limit: :infinity, printable_limit: :infinity)

    binary_contains_forbidden?(inspected, forbidden_binaries) or
      walk_forbidden?(term, forbidden_binaries, allow_ta?)
  end

  defp binary_contains_forbidden?(haystack, forbidden) when is_binary(haystack) do
    Enum.any?(forbidden, fn bin ->
      is_binary(bin) and bin != "" and match?({_pos, _len}, :binary.match(haystack, bin))
    end)
  end

  defp binary_contains_forbidden?(_haystack, _forbidden), do: false

  defp walk_forbidden?(term, forbidden, allow_ta?) when is_struct(term) do
    cond do
      is_struct(term, DeliveryReceipt) ->
        true

      is_struct(term, TurnAuthority) and not allow_ta? ->
        true

      is_struct(term, TurnAuthority) and allow_ta? ->
        # Process-local authority is allowed as a struct. Still scan fields for
        # receipt bearer material; exclude this authority's own id fields.
        own_ids =
          MapSet.new(
            Enum.reject(
              [term.turn_id, term.authenticated_principal_id, term.disclosure_capability_id],
              &is_nil/1
            )
          )

        receipt_bins = Enum.reject(forbidden, &MapSet.member?(own_ids, &1))
        walk_forbidden?(Map.from_struct(term), receipt_bins, allow_ta?)

      true ->
        walk_forbidden?(Map.from_struct(term), forbidden, allow_ta?)
    end
  end

  defp walk_forbidden?(term, forbidden, allow_ta?) when is_map(term) do
    Enum.any?(term, fn {k, v} ->
      walk_forbidden?(k, forbidden, allow_ta?) or walk_forbidden?(v, forbidden, allow_ta?)
    end)
  end

  defp walk_forbidden?(term, forbidden, allow_ta?) when is_list(term) do
    Enum.any?(term, &walk_forbidden?(&1, forbidden, allow_ta?))
  end

  defp walk_forbidden?(term, forbidden, allow_ta?) when is_tuple(term) do
    term |> Tuple.to_list() |> walk_forbidden?(forbidden, allow_ta?)
  end

  defp walk_forbidden?(term, forbidden, _allow_ta?) when is_binary(term) do
    binary_contains_forbidden?(term, forbidden)
  end

  defp walk_forbidden?(_term, _forbidden, _allow_ta?), do: false

  defp receipt_token_hex(receipt) do
    case DeliveryReceipt.bearer_token(receipt) do
      {:ok, token} -> Base.encode16(token, case: :lower)
      _ -> nil
    end
  end

  defp bearer_forbidden_encodings(receipt) do
    assert {:ok, raw} = DeliveryReceipt.bearer_token(receipt)

    [
      raw,
      Base.encode16(raw, case: :lower),
      Base.encode16(raw, case: :upper),
      Base.encode64(raw),
      Base.encode64(raw, padding: false),
      Base.url_encode64(raw),
      Base.url_encode64(raw, padding: false)
    ]
  end

  defp hermetic_success_graph! do
    # Session/Engine authorized runs require IR-compiled graphs (RunAuthorization).
    # Public compile/1 is the same path Session.parse_dot_file uses.
    dot = """
    digraph AuthLeakTurnSuccess {
      graph [goal="VP-05D2A1P2R2 success"]
      start [shape=Mdiamond]
      echo [type="transform", transform="identity", source_key="session.input", output_key="session.response"]
      done [shape=Msquare]
      start -> echo -> done
    }
    """

    assert {:ok, graph} = Orchestrator.compile(dot)
    assert graph.compiled == true
    graph
  end

  defp hermetic_fail_graph! do
    # Real Engine-handled failure: compute simulate="fail" yields
    # {:ok, %{final_outcome: %{status: :fail}}} with a real run_id — not an
    # Elixir error tuple and not a fabricated map.
    dot = """
    digraph AuthLeakTurnFail {
      graph [goal="VP-05D2A1P2R2 deterministic fail"]
      start [shape=Mdiamond]
      fail_node [type="compute", simulate="fail"]
      done [shape=Msquare]
      start -> fail_node -> done
    }
    """

    assert {:ok, graph} = Orchestrator.compile(dot)
    assert graph.compiled == true
    graph
  end

  defp authority_forbidden_binaries(receipt_or_encodings, %TurnAuthority{} = auth) do
    encodings =
      case receipt_or_encodings do
        %DeliveryReceipt{} = receipt -> bearer_forbidden_encodings(receipt)
        list when is_list(list) -> list
      end

    (encodings ++
       [
         auth.turn_id,
         auth.authenticated_principal_id,
         auth.disclosure_capability_id
       ])
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
  end

  defp collect_logs_root_artifacts(session_id) do
    root = session_logs_root(session_id)

    if File.dir?(root) do
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn path ->
        case File.read(path) do
          {:ok, body} -> {path, body}
          _ -> {path, ""}
        end
      end)
    else
      []
    end
  end

  defp flush_mailbox_noise do
    receive do
      {:turn_timeout, _} -> flush_mailbox_noise()
      :drain_queue -> flush_mailbox_noise()
      {:DOWN, _, _, _, _} -> flush_mailbox_noise()
    after
      0 -> :ok
    end
  end

  # Start EventRegistry only when absent; stop only the pid this test started.
  defp ensure_event_registry! do
    name = Arbor.Orchestrator.EventRegistry

    case Process.whereis(name) do
      pid when is_pid(pid) ->
        # Pre-existing — do not own or stop.
        :ok

      nil ->
        case Registry.start_link(keys: :duplicate, name: name) do
          {:ok, pid} ->
            on_exit(fn ->
              stop_owned_event_registry!(name, pid)
            end)

            :ok

          {:error, {:already_started, _pid}} ->
            # Race with another starter — not owned by this test.
            :ok
        end
    end
  end

  defp stop_owned_event_registry!(name, pid) do
    cond do
      Process.whereis(name) == pid ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end

      Process.alive?(pid) ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end

      true ->
        :ok
    end

    # Owned registry must not remain registered under the public name.
    refute Process.whereis(name) == pid

    if Process.whereis(name) == nil do
      :ok
    else
      # Name rebound by someone else after our stop — leave it; we only own `pid`.
      :ok
    end
  end

  defp signal_run_id(signal) do
    data = Map.get(signal, :data) || %{}
    Map.get(data, :run_id) || Map.get(data, "run_id")
  end

  defp drain_signals(tag, acc \\ []) do
    receive do
      {^tag, signal} -> drain_signals(tag, [signal | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Bus delivery is scheduled; poll until terminal lifecycle for run_id or timeout.
  defp await_run_correlated_orchestrator_signals!(run_id, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_orch_signals(run_id, [], deadline)
  end

  defp do_await_orch_signals(run_id, acc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      require_run_correlated_orchestrator_signals!(acc, run_id)
    else
      receive do
        {:orch_signal, signal} ->
          acc = acc ++ [signal]
          correlated = correlated_orch(acc, run_id)
          types = Enum.map(correlated, & &1.type)

          if :pipeline_started in types and
               (:pipeline_completed in types or :pipeline_failed in types) do
            # Drain any stragglers briefly, then return correlated set.
            acc = acc ++ drain_signals(:orch_signal)
            require_run_correlated_orchestrator_signals!(acc, run_id)
          else
            do_await_orch_signals(run_id, acc, deadline)
          end
      after
        min(remaining, 100) ->
          do_await_orch_signals(run_id, acc ++ drain_signals(:orch_signal), deadline)
      end
    end
  end

  defp correlated_orch(signals, run_id) do
    Enum.filter(signals, fn signal ->
      signal.category == :orchestrator and signal_run_id(signal) == run_id
    end)
  end

  defp require_run_correlated_orchestrator_signals!(signals, run_id) do
    correlated = correlated_orch(signals, run_id)

    assert correlated != [],
           "expected run-correlated orchestrator.* signals for #{run_id}, got: #{inspect(signals)}"

    types = Enum.map(correlated, & &1.type)
    assert :pipeline_started in types, "missing pipeline_started for #{run_id}: #{inspect(types)}"

    assert :pipeline_completed in types or :pipeline_failed in types,
           "missing terminal lifecycle signal for #{run_id}: #{inspect(types)}"

    correlated
  end

  # ── Signals topology ownership ───────────────────────────────────────
  # config/test.exs sets arbor_signals start_children: false.
  # Snapshot live / present-dead / absent per child. Start only missing Store
  # then Bus. Ownership kinds:
  #   :new_child       — we inserted the child spec → terminate + delete
  #   :restarted_spec  — spec was present-dead, we restarted → terminate only
  # Pre-existing live children are never owned. Never start Relay/TopicKeys/Channels.

  @signals_needed [Arbor.Signals.Store, Arbor.Signals.Bus]

  defp ensure_signals_stack! do
    {:ok, _} = Application.ensure_all_started(:arbor_signals)
    sup = Arbor.Signals.Supervisor
    needed = @signals_needed

    before = snapshot_signals_topology(sup, needed)
    owned = ensure_signals_children!(sup, needed)

    on_exit(fn ->
      restore_signals_children!(sup, owned)
      assert_signals_topology_restored!(sup, before)
    end)

    assert Signals.healthy?(), "Arbor.Signals Store+Bus must be live for leak signal capture"
    :ok
  end

  defp snapshot_signals_topology(sup, mods) do
    Map.new(mods, fn mod -> {mod, snapshot_signals_child_status(sup, mod)} end)
  end

  defp snapshot_signals_child_status(sup, mod) do
    case List.keyfind(Supervisor.which_children(sup), mod, 0) do
      {^mod, pid, _type, _modules} when is_pid(pid) ->
        if Process.alive?(pid), do: :live, else: :present_dead

      {^mod, :undefined, _type, _modules} ->
        :present_dead

      {^mod, :restarting, _type, _modules} ->
        :present_dead

      nil ->
        # Named process outside this supervisor is still "live" for our purposes
        # only when whereis hits; Store/Bus are always supervisor children.
        if Process.whereis(mod), do: :live, else: :absent
    end
  end

  # Returns [{mod, :new_child | :restarted_spec}, ...] in dependency start order.
  defp ensure_signals_children!(sup, needed) do
    Enum.reduce(needed, [], fn mod, owned ->
      case snapshot_signals_child_status(sup, mod) do
        :live ->
          # Pre-existing live — preserve; do not own.
          owned

        :present_dead ->
          case Supervisor.restart_child(sup, mod) do
            {:ok, _pid} ->
              owned ++ [{mod, :restarted_spec}]

            {:ok, _pid, _info} ->
              owned ++ [{mod, :restarted_spec}]

            {:error, {:already_started, _pid}} ->
              owned

            {:error, reason} ->
              flunk("failed to restart present-dead signals child #{mod}: #{inspect(reason)}")
          end

        :absent ->
          case Supervisor.start_child(sup, {mod, []}) do
            {:ok, _pid} ->
              owned ++ [{mod, :new_child}]

            {:error, {:already_started, _pid}} ->
              owned

            {:error, :already_present} ->
              # Spec appeared as present-dead between snapshot and start.
              case Supervisor.restart_child(sup, mod) do
                {:ok, _pid} ->
                  owned ++ [{mod, :restarted_spec}]

                {:ok, _pid, _info} ->
                  owned ++ [{mod, :restarted_spec}]

                {:error, {:already_started, _}} ->
                  owned

                {:error, reason} ->
                  flunk(
                    "failed to restart already_present signals child #{mod}: #{inspect(reason)}"
                  )
              end

            {:error, reason} ->
              flunk("failed to start signals child #{mod}: #{inspect(reason)}")
          end
      end
    end)
  end

  # Dependency-safe reverse: Bus before Store.
  defp restore_signals_children!(sup, owned) do
    for {mod, kind} <- Enum.reverse(owned) do
      case kind do
        :new_child ->
          _ = Supervisor.terminate_child(sup, mod)
          _ = Supervisor.delete_child(sup, mod)

        :restarted_spec ->
          # Spec pre-existed as present-dead — restore that shape.
          _ = Supervisor.terminate_child(sup, mod)
      end
    end

    :ok
  end

  defp assert_signals_topology_restored!(sup, expected_snapshot) do
    actual = snapshot_signals_topology(sup, Map.keys(expected_snapshot))

    assert actual == expected_snapshot,
           "signals topology not restored exactly: expected #{inspect(expected_snapshot)}, got #{inspect(actual)}"
  end

  describe "security regression: signals topology ownership restore" do
    @tag voice_id: "VOICE-17"
    @tag spec: "VOICE-17"
    test "pre-existing live is preserved; present-dead is terminate-only; new child is deleted" do
      {:ok, _} = Application.ensure_all_started(:arbor_signals)
      sup = Arbor.Signals.Supervisor
      store = Arbor.Signals.Store
      bus = Arbor.Signals.Bus
      needed = [store, bus]

      # Bring Store+Bus live without permanent ownership bookkeeping for this setup step.
      _ = ensure_signals_children!(sup, needed)
      assert snapshot_signals_child_status(sup, store) == :live
      assert snapshot_signals_child_status(sup, bus) == :live

      # ── present-dead path: restart is owned as :restarted_spec → terminate only ──
      _ = Supervisor.terminate_child(sup, bus)
      assert snapshot_signals_child_status(sup, bus) == :present_dead
      assert snapshot_signals_child_status(sup, store) == :live

      before_dead = snapshot_signals_topology(sup, needed)
      owned_dead = ensure_signals_children!(sup, needed)

      assert {bus, :restarted_spec} in owned_dead
      refute Enum.any?(owned_dead, fn {mod, _} -> mod == store end)
      assert snapshot_signals_child_status(sup, bus) == :live

      restore_signals_children!(sup, owned_dead)
      assert_signals_topology_restored!(sup, before_dead)
      assert snapshot_signals_child_status(sup, bus) == :present_dead
      assert snapshot_signals_child_status(sup, store) == :live

      # ── new-child path: start is owned as :new_child → terminate + delete ──
      # Child may already be present-dead; tolerate terminate :not_found.
      _ = Supervisor.terminate_child(sup, bus)
      assert :ok = Supervisor.delete_child(sup, bus)
      assert snapshot_signals_child_status(sup, bus) == :absent

      before_absent = snapshot_signals_topology(sup, needed)
      owned_new = ensure_signals_children!(sup, needed)

      assert {bus, :new_child} in owned_new
      refute Enum.any?(owned_new, fn {mod, _} -> mod == store end)
      assert snapshot_signals_child_status(sup, bus) == :live

      restore_signals_children!(sup, owned_new)
      assert_signals_topology_restored!(sup, before_absent)
      assert snapshot_signals_child_status(sup, bus) == :absent
      assert snapshot_signals_child_status(sup, store) == :live

      # ── pre-existing live: ensure owns nothing; topology unchanged ──
      {:ok, _} = Supervisor.start_child(sup, {bus, []})
      assert snapshot_signals_child_status(sup, bus) == :live

      before_live = snapshot_signals_topology(sup, needed)
      owned_live = ensure_signals_children!(sup, needed)
      assert owned_live == []
      restore_signals_children!(sup, owned_live)
      assert_signals_topology_restored!(sup, before_live)
      assert snapshot_signals_child_status(sup, store) == :live
      assert snapshot_signals_child_status(sup, bus) == :live

      # Leave Store+Bus live for later tests / setup_all cleanup.
      assert Signals.healthy?()
    end

    @tag voice_id: "VOICE-17"
    @tag spec: "VOICE-17"
    test "EventRegistry started by this test is stopped; pre-existing is left alone" do
      name = Arbor.Orchestrator.EventRegistry

      case Process.whereis(name) do
        pid when is_pid(pid) ->
          # Pre-existing: ensure must not stop it.
          assert :ok = ensure_event_registry!()
          assert Process.whereis(name) == pid

        nil ->
          assert :ok = ensure_event_registry!()
          started = Process.whereis(name)
          assert is_pid(started)

          # Simulate the owned on_exit cleanup path.
          stop_owned_event_registry!(name, started)
          assert Process.whereis(name) == nil
      end
    end
  end

  describe "security regression: exact authenticated ingress" do
    test "security regression: queues source-owned engagement after exact consume and principal bind",
         %{
           agent_id: agent_id,
           human_id: human_id,
           resource: resource
         } do
      receipt = issue_receipt!(human_id, resource)
      msg = user_message!(human_id)
      token_hex = receipt_token_hex(receipt)
      from = {self(), make_ref()}

      state =
        session_state(agent_id,
          turn_in_flight: true,
          turn_from: {self(), make_ref()},
          turn_user_message: UserMessage.from_string("active")
        )

      assert {:noreply, new_state} =
               Session.handle_call({:send_authenticated_message, msg, receipt}, from, state)

      assert length(new_state.turn_queue) == 1
      assert [{queued_msg, %TurnAuthority{} = auth, ^from}] = new_state.turn_queue
      assert queued_msg.sender_id == human_id
      assert queued_msg.content == msg.content
      assert queued_msg.engagement_id =~ ~r/^eng_[0-9a-f]{32}$/

      assert {:ok, engagement} = EngagementStore.get(queued_msg.engagement_id)
      assert engagement.agent_id == agent_id
      assert engagement.owner_tenant == human_id
      assert engagement.scope == :user
      assert engagement.visibility == :private

      assert auth.authenticated_principal_id == human_id
      assert auth.disclosure_capability_id == nil
      assert auth.turn_id =~ ~r/^turn_[0-9a-f]{32}$/

      refute term_contains_forbidden?(new_state.turn_queue, [token_hex],
               allow_turn_authority?: true
             )

      refute match?(%DeliveryReceipt{}, elem(hd(new_state.turn_queue), 1))

      # B0 binds provenance but does not enable authenticated steering; B2 owns
      # the typed, turn-bound steering envelope.
      assert {:reply, :none, still_queued} =
               Session.handle_call(:take_steering, {self(), make_ref()}, new_state)

      assert still_queued.turn_queue == new_state.turn_queue

      # Replay must fail closed — receipt already consumed.
      assert {:reply, {:error, :unauthenticated}, returned_replay} =
               Session.handle_call(
                 {:send_authenticated_message, msg, receipt},
                 {self(), make_ref()},
                 state
               )

      assert returned_replay.turn_queue == state.turn_queue
      assert returned_replay.turn_authority == nil
    end

    test "security regression: distinct authenticated humans bind distinct private engagements",
         %{
           agent_id: agent_id,
           human_id: first_human,
           resource: resource
         } do
      second_human = register_active_human!()
      grant!(second_human, resource)

      state =
        session_state(agent_id,
          turn_in_flight: true,
          turn_from: {self(), make_ref()},
          turn_user_message: UserMessage.from_string("active")
        )

      first_from = {self(), make_ref()}
      second_from = {self(), make_ref()}

      assert {:noreply, after_first} =
               Session.handle_call(
                 {:send_authenticated_message, user_message!(first_human),
                  issue_receipt!(first_human, resource)},
                 first_from,
                 state
               )

      assert {:noreply, after_second} =
               Session.handle_call(
                 {:send_authenticated_message, user_message!(second_human),
                  issue_receipt!(second_human, resource)},
                 second_from,
                 after_first
               )

      assert [
               {%UserMessage{} = first_message, %TurnAuthority{} = first_authority, ^first_from},
               {%UserMessage{} = second_message, %TurnAuthority{} = second_authority,
                ^second_from}
             ] = after_second.turn_queue

      refute first_message.engagement_id == second_message.engagement_id
      assert first_authority.authenticated_principal_id == first_human
      assert second_authority.authenticated_principal_id == second_human

      for {message, owner} <- [
            {first_message, first_human},
            {second_message, second_human}
          ] do
        assert message.engagement_id =~ ~r/^eng_[0-9a-f]{32}$/
        assert {:ok, engagement} = EngagementStore.get(message.engagement_id)
        assert engagement.agent_id == agent_id
        assert engagement.owner_tenant == owner
        assert engagement.scope == :user
        assert engagement.visibility == :private
        on_exit(fn -> EngagementStore.delete(message.engagement_id) end)
      end

      # B2 remains the only slice allowed to consume authenticated queue entries
      # as steering, even when their bindings are now explicit.
      assert {:reply, :none, still_queued} =
               Session.handle_call(:take_steering, {self(), make_ref()}, after_second)

      assert still_queued.turn_queue == after_second.turn_queue
    end

    test "security regression: idle start binds canonical engagement before Engine execution", %{
      agent_id: agent_id,
      agent_signer: agent_signer,
      human_id: human_id,
      resource: resource
    } do
      put_orchestrator_cap!(agent_id)
      receipt = issue_receipt!(human_id, resource)
      idle = session_state(agent_id, turn_graph: nil, signer: agent_signer)

      assert {:noreply, started} =
               Session.handle_call(
                 {:send_authenticated_message, user_message!(human_id, "start auth"), receipt},
                 {self(), make_ref()},
                 idle
               )

      assert %TurnAuthority{} = started.turn_authority
      assert started.turn_authority.authenticated_principal_id == human_id
      assert started.turn_authority.disclosure_capability_id == nil
      assert started.turn_in_flight == true

      # This exact message is closed over by the Engine task. The binding is in
      # place before Engine.run/2 can receive the turn input.
      assert %UserMessage{engagement_id: engagement_id} = started.turn_user_message
      assert engagement_id =~ ~r/^eng_[0-9a-f]{32}$/
      assert started.current_engagement_id == engagement_id
      assert {:ok, engagement} = EngagementStore.get(engagement_id)
      assert engagement.agent_id == agent_id
      assert engagement.owner_tenant == human_id
      assert engagement.scope == :user
      assert engagement.visibility == :private
      on_exit(fn -> EngagementStore.delete(engagement_id) end)

      refute term_contains_forbidden?(started, [receipt_token_hex(receipt)],
               allow_turn_authority?: true
             )
    end

    test "security regression: poisoned engagement fails after receipt consumption without state mutation",
         %{
           agent_id: agent_id,
           human_id: human_id,
           resource: resource
         } do
      assert {:ok, canonical} = Comms.resolve_user_engagement(agent_id, human_id)
      on_exit(fn -> EngagementStore.delete(canonical.id) end)

      assert :ok =
               EngagementStore.put(%{
                 canonical
                 | owner_tenant: "human_wrong_owner"
               })

      receipt = issue_receipt!(human_id, resource)
      msg = user_message!(human_id, "poisoned engagement probe")
      from = {self(), make_ref()}

      state =
        session_state(agent_id,
          turn_in_flight: true,
          turn_from: {self(), make_ref()},
          turn_user_message: UserMessage.from_string("active"),
          current_engagement_id: "eng_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          messages: [%{"role" => "user", "content" => "unchanged"}],
          transcripts: %{"eng_public" => []}
        )

      assert {:reply, {:error, :unauthenticated}, returned} =
               Session.handle_call({:send_authenticated_message, msg, receipt}, from, state)

      assert returned == state

      assert {:error, :invalid_receipt} =
               Security.consume_delivery_receipt(receipt, resource, :chat)
    end

    test "sender mismatch consumes receipt and refuses without starting a turn", %{
      agent_id: agent_id,
      human_id: human_id,
      resource: resource
    } do
      receipt = issue_receipt!(human_id, resource)
      wrong = user_message!("human_other_claim")
      from = {self(), make_ref()}
      state = session_state(agent_id)

      assert {:reply, {:error, :unauthenticated}, returned} =
               Session.handle_call({:send_authenticated_message, wrong, receipt}, from, state)

      assert returned.turn_in_flight == false
      assert returned.turn_queue == []
      assert returned.turn_authority == nil
      assert returned.turn_user_message == nil

      # Destructive — replay with corrected sender also fails.
      corrected = user_message!(human_id)

      assert {:reply, {:error, :unauthenticated}, _} =
               Session.handle_call(
                 {:send_authenticated_message, corrected, receipt},
                 from,
                 state
               )
    end

    test "wrong target agent refuses and does not run a turn", %{
      human_id: human_id,
      resource: resource
    } do
      receipt = issue_receipt!(human_id, resource)
      other_agent = "agent_other_#{System.unique_integer([:positive])}"
      msg = user_message!(human_id)
      state = session_state(other_agent)

      assert {:reply, {:error, :unauthenticated}, returned} =
               Session.handle_call(
                 {:send_authenticated_message, msg, receipt},
                 {self(), make_ref()},
                 state
               )

      assert returned.turn_in_flight == false
      assert returned.turn_queue == []
      assert returned.turn_authority == nil
    end

    test "wrong action binding (same resource, non-chat action) refuses and cannot replay", %{
      agent_id: agent_id,
      human_id: human_id,
      resource: resource
    } do
      # Same resource as Session will target, but issued for a non-:chat action.
      # Session always consumes with :chat — action mismatch must refuse.
      receipt = issue_receipt!(human_id, resource, :write)
      msg = user_message!(human_id)
      state = session_state(agent_id)

      assert {:reply, {:error, :unauthenticated}, returned} =
               Session.handle_call(
                 {:send_authenticated_message, msg, receipt},
                 {self(), make_ref()},
                 state
               )

      assert returned.turn_in_flight == false
      assert returned.turn_queue == []
      assert returned.turn_authority == nil

      # Bound to the issued action (or already discarded/failed) — cannot be
      # replayed as a successful :chat ingress either.
      assert {:reply, {:error, :unauthenticated}, _} =
               Session.handle_call(
                 {:send_authenticated_message, msg, receipt},
                 {self(), make_ref()},
                 state
               )
    end

    test "forged and malformed receipts refuse with bounded error", %{
      agent_id: agent_id,
      human_id: human_id
    } do
      msg = user_message!(human_id)
      state = session_state(agent_id)
      from = {self(), make_ref()}

      assert {:ok, forged} = DeliveryReceipt.new(token: :crypto.strong_rand_bytes(32))

      assert {:reply, {:error, :unauthenticated}, returned} =
               Session.handle_call({:send_authenticated_message, msg, forged}, from, state)

      assert returned.turn_in_flight == false
      assert returned.turn_queue == []

      # Embellished forged UserMessage map (extra keys) fails closed.
      embellished = Map.put(msg, :extra_field, "smuggle")
      receipt2 = issue_receipt!(human_id, "arbor://chat/agent/#{agent_id}")

      assert {:reply, {:error, :unauthenticated}, returned2} =
               Session.handle_call(
                 {:send_authenticated_message, embellished, receipt2},
                 from,
                 state
               )

      assert returned2.turn_in_flight == false
      assert returned2.turn_queue == []
    end

    test "legacy mode discards receipt and never authenticates", %{
      agent_id: agent_id,
      human_id: human_id,
      resource: resource
    } do
      receipt = issue_receipt!(human_id, resource)
      msg = user_message!(human_id)
      state = session_state(agent_id, execution_mode: :legacy)

      assert {:reply, {:error, :legacy_mode}, returned} =
               Session.handle_call(
                 {:send_authenticated_message, msg, receipt},
                 {self(), make_ref()},
                 state
               )

      assert returned.turn_authority == nil
      assert returned.turn_queue == []

      # Receipt was discarded — cannot be consumed later.
      assert {:error, :invalid_receipt} =
               Security.consume_delivery_receipt(receipt, resource, :chat)
    end

    test "public API rejects non-exact shapes without leaking", %{
      agent_id: agent_id
    } do
      assert {:error, :unauthenticated} =
               Session.send_authenticated_message(self(), "bare", :not_receipt)

      state = session_state(agent_id)
      assert state.turn_authority == nil
    end

    test "security regression: non-nil engagement_id on authenticated ingress is rejected without turn or engagement switch",
         %{
           agent_id: agent_id,
           human_id: human_id,
           resource: resource
         } do
      owned_messages = [%{"role" => "user", "content" => "owned transcript"}]
      owned_transcripts = %{"eng_other" => [%{"role" => "assistant", "content" => "stashed"}]}

      seed =
        session_state(agent_id,
          current_engagement_id: "eng_owned",
          messages: owned_messages,
          transcripts: owned_transcripts
        )

      receipt = issue_receipt!(human_id, resource)

      foreign_msg =
        human_id
        |> user_message!("cross engagement probe")
        |> UserMessage.with_engagement("eng_foreign_#{System.unique_integer([:positive])}")

      from = {self(), make_ref()}

      assert {:reply, {:error, :unauthenticated}, returned} =
               Session.handle_call(
                 {:send_authenticated_message, foreign_msg, receipt},
                 from,
                 seed
               )

      # Engagement / transcript state must be byte-for-byte unchanged.
      assert returned.current_engagement_id == "eng_owned"
      assert returned.messages == owned_messages
      assert returned.transcripts == owned_transcripts
      assert returned.turn_in_flight == false
      assert returned.turn_queue == []
      assert returned.turn_authority == nil
      assert returned.turn_user_message == nil

      # Public invalidation: receipt cannot be consumed later; no turn started.
      assert {:error, :invalid_receipt} =
               Security.consume_delivery_receipt(receipt, resource, :chat)

      # Mid-flight: still refuse without enqueueing a foreign-engagement turn.
      mid_flight =
        session_state(agent_id,
          turn_in_flight: true,
          turn_from: {self(), make_ref()},
          turn_user_message: UserMessage.from_string("active"),
          current_engagement_id: "eng_owned",
          messages: owned_messages,
          transcripts: owned_transcripts
        )

      receipt2 = issue_receipt!(human_id, resource)

      assert {:reply, {:error, :unauthenticated}, mid_returned} =
               Session.handle_call(
                 {:send_authenticated_message, foreign_msg, receipt2},
                 from,
                 mid_flight
               )

      assert mid_returned.turn_queue == []
      assert mid_returned.current_engagement_id == "eng_owned"
      assert mid_returned.messages == owned_messages
      assert mid_returned.transcripts == owned_transcripts
      assert mid_returned.turn_in_flight == true

      assert {:error, :invalid_receipt} =
               Security.consume_delivery_receipt(receipt2, resource, :chat)
    end
  end

  describe "security regression: queue steering and reset" do
    test "removed unbound steering shape never folds any authority class", %{
      agent_id: agent_id,
      human_id: human_id
    } do
      auth = authority!(human_id)
      auth_from = {self(), make_ref()}
      nil_from = {self(), make_ref()}

      state =
        session_state(agent_id,
          turn_in_flight: true,
          turn_authority: nil,
          turn_user_message: UserMessage.from_string("active nil"),
          turn_queue: [
            {user_message!(human_id, "auth queued"), auth, auth_from},
            {UserMessage.from_string("nil queued"), nil, nil_from}
          ]
        )

      assert {:reply, :none, still} =
               Session.handle_call(:take_steering, {self(), make_ref()}, state)

      # Head retained, order preserved.
      assert still.turn_queue == state.turn_queue
      assert still.steer_froms == []

      # Active authority-bearing blocks fold of nil head too.
      active_auth =
        session_state(agent_id,
          turn_in_flight: true,
          turn_authority: auth,
          turn_user_message: user_message!(human_id, "active auth"),
          turn_queue: [{UserMessage.from_string("nil head"), nil, nil_from}]
        )

      assert {:reply, :none, still_active} =
               Session.handle_call(:take_steering, {self(), make_ref()}, active_auth)

      assert still_active.turn_queue == active_auth.turn_queue

      # Both nil also fail closed through the removed unbound callback shape.
      both_nil =
        session_state(agent_id,
          turn_in_flight: true,
          turn_authority: nil,
          turn_user_message: UserMessage.from_string("active"),
          turn_queue: [{UserMessage.from_string("steer me"), nil, nil_from}]
        )

      assert {:reply, :none, folded} =
               Session.handle_call(:take_steering, {self(), make_ref()}, both_nil)

      assert folded.turn_queue == both_nil.turn_queue
      assert folded.steer_froms == []
    end

    test "authority retained in queue through drain head; reset clears active authority", %{
      agent_id: agent_id,
      human_id: human_id
    } do
      auth = authority!(human_id)
      from = {self(), make_ref()}
      msg = user_message!(human_id, "drained auth turn")
      next_from = {self(), make_ref()}

      in_flight =
        session_state(agent_id,
          turn_in_flight: true,
          turn_authority: auth,
          turn_user_message: msg,
          turn_from: from,
          turn_queue: [
            {user_message!(human_id, "auth next"), auth, next_from},
            {UserMessage.from_string("nil after"), nil, {self(), make_ref()}}
          ]
        )

      # Common reset path clears active authority; queue retains FIFO authority.
      {:reply, :ok, after_cancel} =
        Session.handle_call(:cancel_turn, {self(), make_ref()}, in_flight)

      assert after_cancel.turn_authority == nil
      assert after_cancel.turn_in_flight == false
      assert length(after_cancel.turn_queue) == 2

      assert [{%UserMessage{content: "auth next"}, %TurnAuthority{}, ^next_from} | _] =
               after_cancel.turn_queue

      # Drain tombstone path: skip cancelled task without reordering survivors.
      from_b = {self(), make_ref()}
      from_c = {self(), make_ref()}
      msg_b = %{UserMessage.from_string("b") | transport_metadata: %{task_id: "task_b"}}

      drain_state =
        session_state(agent_id,
          cancelled_task_ids: %{"task_b" => true},
          cancelled_task_id_order: ["task_b"],
          turn_queue: [
            {msg_b, auth, from_b},
            {UserMessage.from_string("c work"), nil, from_c}
          ]
        )

      assert {:noreply, after_b} = Session.handle_info(:drain_queue, drain_state)
      assert length(after_b.turn_queue) == 1
      assert match?({%UserMessage{content: "c work"}, nil, _}, hd(after_b.turn_queue))
      refute after_b.turn_in_flight
    end

    test "direct send_message always carries nil authority in the queue", %{
      agent_id: agent_id
    } do
      from = {self(), make_ref()}

      state =
        session_state(agent_id,
          turn_in_flight: true,
          turn_from: {self(), make_ref()},
          turn_user_message: UserMessage.from_string("active"),
          turn_authority: nil
        )

      assert {:noreply, new_state} =
               Session.handle_call({:send_message, "compat direct"}, from, state)

      assert [{%UserMessage{}, nil, ^from}] = new_state.turn_queue
    end

    test "cancel_task purge retains triple ordering semantics", %{
      agent_id: agent_id,
      human_id: human_id
    } do
      auth = authority!(human_id)
      from_b = {self(), make_ref()}
      from_c = {self(), make_ref()}

      msg_b = %{UserMessage.from_string("b") | transport_metadata: %{task_id: "task_b"}}

      state =
        session_state(agent_id,
          turn_in_flight: true,
          turn_user_message: UserMessage.from_string("active"),
          turn_from: {self(), make_ref()},
          turn_queue: [
            {msg_b, auth, from_b},
            {UserMessage.from_string("c"), nil, from_c}
          ]
        )

      assert {:reply, :ok, new_state} =
               Session.handle_call({:cancel_task, "task_b"}, {self(), make_ref()}, state)

      assert length(new_state.turn_queue) == 1
      assert [{%UserMessage{content: "c"}, nil, ^from_c}] = new_state.turn_queue
    end
  end

  describe "security regression: leak checks" do
    test "builders and engine values never carry authority or receipt material", %{
      agent_id: agent_id,
      human_id: human_id,
      resource: resource
    } do
      receipt = issue_receipt!(human_id, resource)
      token_hex = receipt_token_hex(receipt)
      msg = user_message!(human_id)
      auth = authority!(human_id)
      from = {self(), make_ref()}

      state =
        session_state(agent_id,
          turn_in_flight: true,
          turn_from: {self(), make_ref()},
          turn_user_message: UserMessage.from_string("active")
        )

      assert {:noreply, queued} =
               Session.handle_call({:send_authenticated_message, msg, receipt}, from, state)

      [{_qmsg, %TurnAuthority{} = qauth, _}] = queued.turn_queue
      forbidden = [token_hex, qauth.turn_id, qauth.authenticated_principal_id]

      values = Builders.build_turn_values(queued, msg.content)
      opts = Builders.build_engine_opts(queued, values)

      # Engine/builder artifacts must not carry TurnAuthority structs or raw ids.
      refute term_contains_forbidden?(values, forbidden, allow_turn_authority?: false)

      serializable_opts =
        opts
        |> Enum.reject(fn {_k, v} -> is_function(v) end)
        |> Map.new()

      refute term_contains_forbidden?(serializable_opts, forbidden, allow_turn_authority?: false)
      refute term_contains_forbidden?(values, [token_hex], allow_turn_authority?: false)

      # Public error shape is bounded.
      err = {:error, :unauthenticated}
      refute term_contains_forbidden?(err, forbidden, allow_turn_authority?: false)

      # Inspected Session projection redacts authority fields when present.
      with_auth = %{queued | turn_authority: auth}

      assert {:reply, projected, ^with_auth} =
               Session.handle_call(:get_state, {self(), make_ref()}, with_auth)

      inspected = inspect(projected, limit: :infinity, printable_limit: :infinity)
      refute inspected =~ auth.turn_id
      refute inspected =~ auth.authenticated_principal_id
      refute term_contains_forbidden?(projected, forbidden, allow_turn_authority?: false)
    end

    test "public get_state strips active and queued TurnAuthority; internal state unchanged", %{
      agent_id: agent_id,
      human_id: human_id
    } do
      auth = authority!(human_id)
      queue_from = {self(), make_ref()}
      compat_from = {self(), make_ref()}

      active_msg =
        human_id
        |> user_message!("active with auth")
        |> Map.merge(%{sender: human_id, transport_metadata: %{principal: human_id}})

      msg =
        human_id
        |> user_message!("queued with auth")
        |> Map.merge(%{sender: human_id, transport_metadata: %{principal: human_id}})

      compat_msg = user_message!("human_compat_projection", "nil authority compatibility")

      internal =
        session_state(agent_id,
          turn_in_flight: true,
          turn_authority: auth,
          turn_user_message: active_msg,
          turn_from: {self(), make_ref()},
          turn_queue: [{msg, auth, queue_from}, {compat_msg, nil, compat_from}]
        )

      assert {:reply, projected, still_internal} =
               Session.handle_call(:get_state, {self(), make_ref()}, internal)

      # Public projection: no TurnAuthority structs or authority ids escape.
      assert projected.turn_authority == nil

      assert %UserMessage{
               content: "active with auth",
               sender: nil,
               sender_id: nil,
               transport_metadata: %{}
             } = projected.turn_user_message

      assert [
               {%UserMessage{
                  content: "queued with auth",
                  sender: nil,
                  sender_id: nil,
                  transport_metadata: %{}
                }, nil, ^queue_from},
               {^compat_msg, nil, ^compat_from}
             ] = projected.turn_queue

      projected_inspected = inspect(projected, limit: :infinity, printable_limit: :infinity)
      refute projected_inspected =~ auth.turn_id
      refute projected_inspected =~ auth.authenticated_principal_id

      refute term_contains_forbidden?(projected, [auth.turn_id, auth.authenticated_principal_id],
               allow_turn_authority?: false
             )

      # Internal GenServer state is unchanged (authority retained process-locally).
      assert still_internal.turn_authority == auth
      assert still_internal.turn_user_message == active_msg

      assert [{^msg, ^auth, ^queue_from}, {^compat_msg, nil, ^compat_from}] =
               still_internal.turn_queue

      assert still_internal.turn_authority.turn_id == auth.turn_id
      assert still_internal.turn_authority.authenticated_principal_id == human_id
    end

    test "security regression: real Engine success/fail envelopes admit only success; no receipt/authority leak",
         %{
           agent_id: agent_id,
           agent_signer: agent_signer,
           human_id: human_id,
           resource: resource
         } do
      ensure_signals_stack!()
      ensure_event_registry!()
      put_orchestrator_cap!(agent_id)
      success_graph = hermetic_success_graph!()
      fail_graph = hermetic_fail_graph!()
      test_pid = self()

      assert {:ok, agent_sub_id} =
               Signals.subscribe(
                 "agent.query_completed",
                 fn signal ->
                   send(test_pid, {:agent_signal, signal})
                   :ok
                 end,
                 async: false
               )

      assert {:ok, orch_sub_id} =
               Signals.subscribe(
                 "orchestrator.*",
                 fn signal ->
                   send(test_pid, {:orch_signal, signal})
                   :ok
                 end,
                 async: false
               )

      on_exit(fn ->
        if Process.whereis(Arbor.Signals.Bus) do
          _ = Signals.unsubscribe(agent_sub_id)
          _ = Signals.unsubscribe(orch_sub_id)
        end
      end)

      adapters = %{
        checkpoint_save: fn session_id, data ->
          send(test_pid, {:checkpoint_saved, session_id, data})
          :ok
        end
      }

      # ── Success path: real compiled graph, lifecycle signals, agent completion ──
      receipt = issue_receipt!(human_id, resource)
      bearer_encodings = bearer_forbidden_encodings(receipt)
      content = "hermetic auth leak probe #{System.unique_integer([:positive])}"
      msg = user_message!(human_id, content)
      from = {self(), make_ref()}

      idle =
        session_state(agent_id,
          turn_graph: success_graph,
          signer: agent_signer,
          adapters: adapters,
          pid: self(),
          config: %{"stream" => false, checkpoint_interval: 1},
          turn_count: 0
        )

      assert {:noreply, started} =
               Session.handle_call({:send_authenticated_message, msg, receipt}, from, idle)

      assert %TurnAuthority{} = started.turn_authority
      auth = started.turn_authority
      forbidden = authority_forbidden_binaries(bearer_encodings, auth)

      # Receipt encodings never retained on process-local state (TA fields OK process-locally).
      refute term_contains_forbidden?(started, bearer_encodings, allow_turn_authority?: true)

      assert_receive {:turn_result, turn_token, received_msg, engine_outcome}, 10_000
      assert is_reference(turn_token)
      assert turn_token == started.turn_token
      assert received_msg.content == content
      assert received_msg.engagement_id == started.turn_user_message.engagement_id
      assert received_msg.engagement_id =~ ~r/^eng_[0-9a-f]{32}$/

      assert match?(
               {:ok, %{final_outcome: %{status: :success}, run_id: rid}} when is_binary(rid),
               engine_outcome
             ),
             "expected hermetic Engine success, got: #{inspect(engine_outcome)}"

      {:ok, run_result} = engine_outcome
      success_run_id = run_result.run_id
      assert is_binary(success_run_id) and success_run_id != ""

      refute term_contains_forbidden?(run_result, forbidden, allow_turn_authority?: false)
      refute term_contains_forbidden?(run_result.context, forbidden, allow_turn_authority?: false)

      orch_success = await_run_correlated_orchestrator_signals!(success_run_id)

      Enum.each(orch_success, fn signal ->
        refute term_contains_forbidden?(signal, forbidden, allow_turn_authority?: false)
      end)

      logs_artifacts = collect_logs_root_artifacts(started.session_id)
      assert logs_artifacts != [], "expected Engine log artifacts under session log root"
      refute term_contains_forbidden?(logs_artifacts, forbidden, allow_turn_authority?: false)

      # Drive the real Session completion path (admission → apply/checkpoint/signal).
      assert {:noreply, after_success} =
               Session.handle_info(
                 {:turn_result, turn_token, received_msg, engine_outcome},
                 started
               )

      assert after_success.turn_count == 1

      assert_receive {:checkpoint_saved, ckpt_session_id, checkpoint_data}, 5_000
      assert ckpt_session_id == started.session_id
      assert is_map(checkpoint_data)
      refute term_contains_forbidden?(checkpoint_data, forbidden, allow_turn_authority?: false)

      assert_receive {:agent_signal, emitted_signal}, 5_000
      assert emitted_signal.category == :agent
      assert emitted_signal.type == :query_completed
      refute term_contains_forbidden?(emitted_signal, forbidden, allow_turn_authority?: false)

      refute term_contains_forbidden?(emitted_signal.data, forbidden,
               allow_turn_authority?: false
             )

      refute term_contains_forbidden?(emitted_signal.metadata, forbidden,
               allow_turn_authority?: false
             )

      flush_mailbox_noise()

      assert {:reply, projected, _} =
               Session.handle_call(:get_state, {self(), make_ref()}, after_success)

      refute term_contains_forbidden?(projected, forbidden, allow_turn_authority?: false)

      {_from_pid, from_ref} = from
      assert_receive {^from_ref, public_reply}, 1_000
      assert {:ok, _} = public_reply
      refute term_contains_forbidden?(public_reply, forbidden, allow_turn_authority?: false)

      # ── Failure path: real deterministic fail graph → bounded :turn_failed ──
      # Behavioral base-fail proof: without admission, Session would apply this
      # {:ok, %{final_outcome: %{status: :fail}}} envelope as success.
      flush_mailbox_noise()
      _ = drain_signals(:orch_signal)
      _ = drain_signals(:agent_signal)

      receipt_fail = issue_receipt!(human_id, resource)
      fail_bearer = bearer_forbidden_encodings(receipt_fail)
      msg_fail = user_message!(human_id, "fail path leak probe")
      fail_from = {self(), make_ref()}
      {_fail_pid, fail_ref} = fail_from

      idle_fail =
        session_state(agent_id,
          turn_graph: fail_graph,
          signer: agent_signer,
          adapters: adapters,
          pid: self(),
          config: %{"stream" => false, checkpoint_interval: 1},
          turn_count: 0,
          messages: []
        )

      assert {:noreply, started_fail} =
               Session.handle_call(
                 {:send_authenticated_message, msg_fail, receipt_fail},
                 fail_from,
                 idle_fail
               )

      assert %TurnAuthority{} = started_fail.turn_authority
      fail_auth = started_fail.turn_authority
      fail_forbidden = authority_forbidden_binaries(fail_bearer, fail_auth)

      refute term_contains_forbidden?(started_fail, fail_bearer, allow_turn_authority?: true)

      assert_receive {:turn_result, fail_token, fail_msg, fail_outcome}, 10_000
      assert is_reference(fail_token)
      assert fail_token == started_fail.turn_token
      assert fail_msg.content == "fail path leak probe"

      # Real Engine failure envelope (not Elixir error, not fabricated).
      assert match?(
               {:ok, %{final_outcome: %{status: :fail}, run_id: rid}} when is_binary(rid),
               fail_outcome
             ),
             "expected real Engine :fail envelope, got: #{inspect(fail_outcome)}"

      {:ok, fail_result} = fail_outcome
      fail_run_id = fail_result.run_id
      assert is_binary(fail_run_id) and fail_run_id != ""
      refute fail_run_id == success_run_id

      refute term_contains_forbidden?(fail_result, fail_forbidden, allow_turn_authority?: false)

      refute term_contains_forbidden?(fail_result.context, fail_forbidden,
               allow_turn_authority?: false
             )

      orch_fail = await_run_correlated_orchestrator_signals!(fail_run_id)

      Enum.each(orch_fail, fn signal ->
        refute term_contains_forbidden?(signal, fail_forbidden, allow_turn_authority?: false)
      end)

      fail_logs = collect_logs_root_artifacts(started_fail.session_id)
      assert fail_logs != [], "expected Engine log artifacts for fail run"
      refute term_contains_forbidden?(fail_logs, fail_forbidden, allow_turn_authority?: false)

      # Session admission rejects before apply/checkpoint/success signal.
      assert {:noreply, after_fail} =
               Session.handle_info(
                 {:turn_result, fail_token, fail_msg, fail_outcome},
                 started_fail
               )

      assert after_fail.turn_count == 0
      assert after_fail.messages == []
      assert after_fail.turn_in_flight == false
      assert after_fail.turn_authority == nil

      # No successful Session checkpoint from rejected envelope.
      refute_receive {:checkpoint_saved, _, _}, 200

      # Explicitly prove no agent.query_completed on failure.
      agent_after_fail = drain_signals(:agent_signal)
      assert agent_after_fail == [], "fail path must not emit agent.query_completed"

      flush_mailbox_noise()

      assert {:reply, fail_projected, _} =
               Session.handle_call(:get_state, {self(), make_ref()}, after_fail)

      refute term_contains_forbidden?(fail_projected, fail_forbidden,
               allow_turn_authority?: false
             )

      assert_receive {^fail_ref, fail_public_reply}, 1_000
      # Closed bounded public error — never raw Engine failure_reason.
      assert fail_public_reply == {:error, :turn_failed}

      refute term_contains_forbidden?(fail_public_reply, fail_forbidden,
               allow_turn_authority?: false
             )

      fail_inspected = inspect(fail_public_reply, limit: :infinity, printable_limit: :infinity)

      Enum.each(fail_bearer, fn enc ->
        if is_binary(enc) and enc != "" do
          refute fail_inspected =~ enc
        end
      end)

      refute fail_inspected =~ fail_auth.turn_id
      refute fail_inspected =~ fail_auth.authenticated_principal_id

      # Simulated failure_reason must not leak into the public reply.
      refute fail_inspected =~ "simulated failure"

      unauth = {:error, :unauthenticated}
      refute term_contains_forbidden?(unauth, fail_forbidden, allow_turn_authority?: false)
    end
  end

  describe "VP-05D2A1P2R3 timeout-bearing send_authenticated_message/4" do
    @tag voice_id: "VOICE-17"
    @tag spec: "VOICE-17"
    test "/3 uses Config.turn_timeout_ms and exact authenticated tuple from original caller", %{
      human_id: human_id,
      resource: resource
    } do
      short_ms = 80
      prev = Application.get_env(:arbor_orchestrator, :turn_timeout_ms)

      Application.put_env(:arbor_orchestrator, :turn_timeout_ms, short_ms)

      on_exit(fn ->
        if is_nil(prev) do
          Application.delete_env(:arbor_orchestrator, :turn_timeout_ms)
        else
          Application.put_env(:arbor_orchestrator, :turn_timeout_ms, prev)
        end
      end)

      parent = self()
      msg = user_message!(human_id)
      receipt = issue_receipt!(human_id, resource)
      caller = self()

      # Bare process speaking GenServer.call protocol (not Session; no helper facade).
      delay_pid =
        spawn(fn ->
          receive do
            {:"$gen_call", from, request} ->
              send(parent, {:recorded_call, elem(from, 0), request})
              # Never reply; hold past the configured timeout.
              Process.sleep(short_ms * 20)
          end
        end)

      on_exit(fn ->
        if Process.alive?(delay_pid), do: Process.exit(delay_pid, :kill)
      end)

      exit_reason =
        catch_exit(Session.send_authenticated_message(delay_pid, msg, receipt))

      assert {:timeout, {GenServer, :call, [^delay_pid, request, ^short_ms]}} = exit_reason
      assert request == {:send_authenticated_message, msg, receipt}

      assert_receive {:recorded_call, recorded_caller, recorded_request}, 1_000
      assert recorded_caller == caller
      assert recorded_request == {:send_authenticated_message, msg, receipt}
    end

    @tag voice_id: "VOICE-17"
    @tag spec: "VOICE-17"
    test "/4 uses supplied timeout and original caller PID with exact authenticated tuple", %{
      human_id: human_id,
      resource: resource
    } do
      supplied_ms = 50
      # Leave configured timeout large so a hang would exceed wall-clock bound.
      configured = Arbor.Orchestrator.Config.turn_timeout_ms()
      assert configured > supplied_ms * 20

      parent = self()
      msg = user_message!(human_id)
      receipt = issue_receipt!(human_id, resource)
      caller = self()

      delay_pid =
        spawn(fn ->
          receive do
            {:"$gen_call", from, request} ->
              send(parent, {:recorded_call, elem(from, 0), request})
              Process.sleep(supplied_ms * 40)
          end
        end)

      on_exit(fn ->
        if Process.alive?(delay_pid), do: Process.exit(delay_pid, :kill)
      end)

      started = System.monotonic_time(:millisecond)

      exit_reason =
        catch_exit(Session.send_authenticated_message(delay_pid, msg, receipt, supplied_ms))

      elapsed = System.monotonic_time(:millisecond) - started

      assert {:timeout, {GenServer, :call, [^delay_pid, request, ^supplied_ms]}} = exit_reason
      assert request == {:send_authenticated_message, msg, receipt}
      # Bounded by supplied timeout, not configured Session turn timeout.
      assert elapsed < configured
      assert elapsed < supplied_ms * 10

      assert_receive {:recorded_call, recorded_caller, recorded_request}, 1_000
      assert recorded_caller == caller
      assert recorded_request == {:send_authenticated_message, msg, receipt}
    end

    @tag voice_id: "VOICE-17"
    @tag spec: "VOICE-17"
    test "invalid /4 arguments send no message and return invalid_authenticated_message_request",
         %{
           human_id: human_id,
           resource: resource
         } do
      parent = self()
      msg = user_message!(human_id)
      receipt = issue_receipt!(human_id, resource)

      probe =
        spawn(fn ->
          receive do
            inbound -> send(parent, {:probe_received, inbound})
          end
        end)

      on_exit(fn ->
        if Process.alive?(probe), do: Process.exit(probe, :kill)
      end)

      assert {:error, :invalid_authenticated_message_request} =
               Session.send_authenticated_message(probe, msg, receipt, 0)

      assert {:error, :invalid_authenticated_message_request} =
               Session.send_authenticated_message(probe, msg, receipt, -1)

      assert {:error, :invalid_authenticated_message_request} =
               Session.send_authenticated_message(probe, msg, receipt, 1.5)

      assert {:error, :invalid_authenticated_message_request} =
               Session.send_authenticated_message(probe, msg, receipt, :infinity)

      assert {:error, :invalid_authenticated_message_request} =
               Session.send_authenticated_message(probe, "bare", receipt, 50)

      assert {:error, :invalid_authenticated_message_request} =
               Session.send_authenticated_message(probe, msg, :not_receipt, 50)

      # Receipt remains caller-owned (never submitted / consumed by Session).
      assert {:ok, _principal} =
               Security.consume_delivery_receipt(receipt, resource, :chat)

      refute_receive {:probe_received, _}, 100
    end

    @tag voice_id: "VOICE-17"
    @tag spec: "VOICE-17"
    test "/3 invalid inputs retain unauthenticated" do
      assert {:error, :unauthenticated} =
               Session.send_authenticated_message(self(), "bare", :not_receipt)
    end
  end
end

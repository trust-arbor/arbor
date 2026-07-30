defmodule Arbor.AI.RouteFailureAndRecordTest do
  use ExUnit.Case, async: false

  alias Arbor.AI
  alias Arbor.AI.{LLMError, QuotaTracker, RouteFailureStore}
  alias Arbor.AI.Runtime.{OAuthHealthObservation, RouteEvidenceOverlay, RouteInputAssembler}
  alias Arbor.Contracts.LLM.{ModelEntry, ProviderEntry, ProviderObservation}
  alias Arbor.LLM.OAuth.ResponsesFailure

  @moduletag :fast
  @now ~U[2026-07-22 22:00:00Z]

  setup do
    RouteFailureStore.clear_sync(:openai_oauth)
    RouteFailureStore.clear_sync(:xai_oauth)
    QuotaTracker.clear_sync(:openai_oauth)
    QuotaTracker.clear_sync(:xai_oauth)
    :ok
  end

  test "sync quota record is visible immediately for exact route only" do
    info =
      LLMError.classify(
        ResponsesFailure.exception(
          route: :openai_oauth,
          backend: :openai,
          code: :rate_limited,
          status: 429,
          retry_after_ms: 60_000
        )
      )

    assert {:ok, :recorded} = AI.record_classified_llm_failure(info)

    assert {:ok, status} = QuotaTracker.snapshot_status()
    assert %{available: false} = status["openai_oauth"]
    refute Map.has_key?(status, "xai_oauth")
    refute Map.has_key?(status, "openai")
  end

  test "security regression: aliases or missing route cannot update another route" do
    for bad <- [
          %{type: :rate_limited, code: "rate_limited", provider: :openai, retry_after_ms: 1_000},
          %{type: :rate_limited, code: "rate_limited", provider: "openai", retry_after_ms: 1_000},
          %{type: :rate_limited, code: "rate_limited", provider: :xai, retry_after_ms: 1_000},
          %{type: :rate_limited, code: "rate_limited", provider: nil, retry_after_ms: 1_000},
          %{type: :rate_limited, code: "rate_limited", provider: :grok, retry_after_ms: 1_000}
        ] do
      assert {:ok, :noop} = AI.record_classified_llm_failure(bad)
    end

    assert {:ok, status} = QuotaTracker.snapshot_status()
    refute Map.has_key?(status, "openai_oauth")
    refute Map.has_key?(status, "xai_oauth")
    refute Map.has_key?(status, "openai")
  end

  test "security regression: type-only maps cannot mutate quota or route-failure state" do
    for bad <- [
          %{type: :rate_limited, provider: :openai_oauth, retry_after_ms: 1_000},
          %{type: :auth_failure, provider: :openai_oauth},
          %{type: :rate_limited, code: nil, provider: :openai_oauth},
          %{type: :auth_failure, code: "unauthorized", provider: :openai}
        ] do
      assert {:ok, :noop} = AI.record_classified_llm_failure(bad)
    end

    assert {:ok, quota} = QuotaTracker.snapshot_status()
    refute Map.has_key?(quota, "openai_oauth")
    assert {:ok, failures} = RouteFailureStore.snapshot_status(now: DateTime.utc_now())
    refute Map.has_key?(failures, "openai_oauth")
  end

  test "security regression: non-quota failures do not poison quota" do
    for class_code <- [
          {:auth, :unauthorized},
          {:tier_denied, :xai_oauth_tier_denied},
          {:transport, :connection_failed},
          {:protocol, :invalid_stream},
          {:provider_outage, :server_error}
        ] do
      {class, code} = class_code
      route = if class == :tier_denied, do: :xai_oauth, else: :openai_oauth
      backend = if route == :xai_oauth, do: :xai, else: :openai

      info =
        LLMError.classify(
          ResponsesFailure.exception(route: route, backend: backend, code: code, status: 403)
        )

      assert {:ok, :recorded} = AI.record_classified_llm_failure(info)
    end

    assert {:ok, quota} = QuotaTracker.snapshot_status()
    refute Map.has_key?(quota, "openai_oauth")
    refute Map.has_key?(quota, "xai_oauth")

    assert {:ok, failures} = RouteFailureStore.snapshot_status(now: DateTime.utc_now())
    assert Map.has_key?(failures, "openai_oauth") or Map.has_key?(failures, "xai_oauth")
  end

  test "tier_denied semantic code is retained and makes route unselectable via overlay" do
    info =
      LLMError.classify(
        ResponsesFailure.exception(
          route: :xai_oauth,
          backend: :xai,
          code: :xai_oauth_tier_denied,
          status: 403
        )
      )

    assert {:ok, :recorded} = AI.record_classified_llm_failure(info)
    assert {:ok, failures} = RouteFailureStore.snapshot_status(now: DateTime.utc_now())
    assert %{class: :tier_denied} = failures["xai_oauth"]

    base = base_obs("xai_oauth")
    overlaid = RouteEvidenceOverlay.overlay(base, failures["xai_oauth"], nil, @now)
    assert overlaid["availability"] == "unavailable"
    assert overlaid["subscription_capacity_state"] == "exhausted"
    assert overlaid["failure_code"] == "tier_denied"
    refute overlaid["failure_code"] == "account_exhausted"

    assert {:ok, %ProviderObservation{} = obs} = ProviderObservation.new(overlaid)
    assert obs.availability == "unavailable"
    assert obs.subscription_capacity_state == "exhausted"
    assert obs.failure_code == "tier_denied"
  end

  test "transport protocol and outage overlays use distinct semantic codes" do
    base = base_obs("openai_oauth")

    transport = %{
      class: :transport,
      code: "connection_failed",
      expires_at: DateTime.add(@now, 60, :second)
    }

    protocol = %{
      class: :protocol,
      code: "invalid_stream",
      expires_at: DateTime.add(@now, 60, :second)
    }

    outage = %{
      class: :outage,
      code: "server_error",
      expires_at: DateTime.add(@now, 60, :second)
    }

    assert RouteEvidenceOverlay.overlay(base, transport, nil, @now)["failure_code"] ==
             "transport_error"

    assert RouteEvidenceOverlay.overlay(base, protocol, nil, @now)["failure_code"] ==
             "protocol_error"

    out = RouteEvidenceOverlay.overlay(base, outage, nil, @now)
    assert out["failure_code"] == "provider_outage"
    refute out["failure_code"] == "unknown"
    assert out["failure_message"] == "provider outage"
  end

  test "competing failure severity is order-independent for both arrival orders" do
    observed = DateTime.utc_now()

    put = fn class, code ->
      assert :ok =
               RouteFailureStore.put_sync(
                 route: "openai_oauth",
                 class: class,
                 code: code,
                 retryable: false,
                 observed_at: observed,
                 expires_at: DateTime.add(observed, 300, :second)
               )
    end

    # transport then auth → auth wins
    put.(:transport, "connection_failed")
    put.(:auth, "unauthorized")

    assert {:ok, %{"openai_oauth" => %{class: :auth}}} =
             RouteFailureStore.snapshot_status(now: observed)

    RouteFailureStore.clear_sync(:openai_oauth)

    # auth then transport → auth retained
    put.(:auth, "unauthorized")
    put.(:transport, "connection_failed")

    assert {:ok, %{"openai_oauth" => %{class: :auth}}} =
             RouteFailureStore.snapshot_status(now: observed)

    RouteFailureStore.clear_sync(:openai_oauth)

    # protocol then tier_denied → tier_denied; reverse retains tier_denied
    put.(:protocol, "invalid_stream")
    put.(:tier_denied, "xai_oauth_tier_denied")

    assert {:ok, %{"openai_oauth" => %{class: :tier_denied}}} =
             RouteFailureStore.snapshot_status(now: observed)

    put.(:protocol, "invalid_stream")

    assert {:ok, %{"openai_oauth" => %{class: :tier_denied}}} =
             RouteFailureStore.snapshot_status(now: observed)

    RouteFailureStore.clear_sync(:openai_oauth)

    put.(:transport, "connection_failed")
    put.(:outage, "server_error")

    assert {:ok, %{"openai_oauth" => %{class: :outage}}} =
             RouteFailureStore.snapshot_status(now: observed)

    put.(:transport, "request_timeout")

    assert {:ok, %{"openai_oauth" => %{class: :outage}}} =
             RouteFailureStore.snapshot_status(now: observed)
  end

  test "false retryable boolean is preserved and non-booleans are rejected" do
    observed = DateTime.utc_now()

    assert :ok =
             RouteFailureStore.put_sync(
               route: "openai_oauth",
               class: :transport,
               code: "connection_failed",
               retryable: false,
               observed_at: observed,
               expires_at: DateTime.add(observed, 60, :second)
             )

    assert {:ok, %{"openai_oauth" => %{retryable: false}}} =
             RouteFailureStore.snapshot_status(now: observed)

    assert {:error, :rejected} =
             RouteFailureStore.put_sync(
               route: "xai_oauth",
               class: :auth,
               code: "unauthorized",
               retryable: "false",
               observed_at: observed,
               expires_at: DateTime.add(observed, 60, :second)
             )
  end

  test "explicit expiry is capped to reviewed maximum" do
    # Must be wall-clock-current: put rejects already-expired entries after the
    # reviewed max TTL clamp (observed_at + 24h). A fixed past observed_at would
    # make the clamped expires_at inactive and reject the put.
    observed = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    far = DateTime.add(observed, 10 * 86_400, :second)

    assert :ok =
             RouteFailureStore.put_sync(
               route: "openai_oauth",
               class: :auth,
               code: "unauthorized",
               retryable: false,
               observed_at: observed,
               expires_at: far
             )

    assert {:ok, %{"openai_oauth" => entry}} =
             RouteFailureStore.snapshot_status(now: observed)

    max = DateTime.add(observed, 86_400_000, :millisecond)
    assert DateTime.compare(entry.expires_at, max) != :gt
    assert DateTime.compare(entry.expires_at, max) == :eq
  end

  test "negative retry_after_ms is rejected rather than defaulting TTL" do
    observed = DateTime.utc_now()

    assert {:error, :rejected} =
             RouteFailureStore.put_sync(
               route: "openai_oauth",
               class: :transport,
               code: "connection_failed",
               retryable: true,
               observed_at: observed,
               retry_after_ms: -1
             )

    assert {:ok, failures} = RouteFailureStore.snapshot_status(now: observed)
    refute Map.has_key?(failures, "openai_oauth")
  end

  test "already-expired put is rejected and does not replace active evidence" do
    now = DateTime.utc_now()
    active_obs = DateTime.add(now, -10, :second)
    stale_obs = DateTime.add(now, -600, :second)

    assert :ok =
             RouteFailureStore.put_sync(
               route: "openai_oauth",
               class: :transport,
               code: "connection_failed",
               retryable: true,
               observed_at: active_obs,
               expires_at: DateTime.add(now, 300, :second)
             )

    # Older high-severity event that is already expired must not clobber newer active transport.
    assert {:error, :rejected} =
             RouteFailureStore.put_sync(
               route: "openai_oauth",
               class: :auth,
               code: "unauthorized",
               retryable: false,
               observed_at: stale_obs,
               expires_at: DateTime.add(now, -1, :second)
             )

    assert {:ok, %{"openai_oauth" => %{class: :transport}}} =
             RouteFailureStore.snapshot_status(now: now)
  end

  test "severity merge is order-independent for active entries with different observed_at" do
    now = DateTime.utc_now()
    # Auth observed earlier; transport observed later — both still active.
    auth_obs = DateTime.add(now, -120, :second)
    transport_obs = DateTime.add(now, -5, :second)
    auth_expires = DateTime.add(now, 300, :second)
    transport_expires = DateTime.add(now, 300, :second)

    auth = [
      route: "openai_oauth",
      class: :auth,
      code: "unauthorized",
      retryable: false,
      observed_at: auth_obs,
      expires_at: auth_expires
    ]

    transport = [
      route: "openai_oauth",
      class: :transport,
      code: "connection_failed",
      retryable: true,
      observed_at: transport_obs,
      expires_at: transport_expires
    ]

    assert :ok = RouteFailureStore.put_sync(auth)
    assert :ok = RouteFailureStore.put_sync(transport)
    assert {:ok, first} = RouteFailureStore.snapshot_status(now: now)

    RouteFailureStore.clear_sync(:openai_oauth)

    assert :ok = RouteFailureStore.put_sync(transport)
    assert :ok = RouteFailureStore.put_sync(auth)
    assert {:ok, second} = RouteFailureStore.snapshot_status(now: now)

    # Same two active events → identical public entry regardless of arrival order.
    assert first == second
    assert %{class: :auth, code: "unauthorized", observed_at: ^auth_obs} = first["openai_oauth"]
  end

  test "malformed list attrs to put_sync are rejected without crashing the store" do
    pid = Process.whereis(RouteFailureStore)
    assert is_pid(pid)

    # Improper / non-keyword lists must not raise via Map.new/1.
    assert {:error, :rejected} = RouteFailureStore.put_sync([:not_a_keyword_pair])
    assert {:error, :rejected} = RouteFailureStore.put_sync([{"string_key", 1}])

    assert {:error, :rejected} =
             RouteFailureStore.put_sync([{:route, "openai_oauth"} | :improper])

    assert {:error, :rejected} = RouteFailureStore.put_sync("not a map or keyword")

    assert Process.alive?(pid)
    assert Process.whereis(RouteFailureStore) == pid
    assert {:ok, %{}} = RouteFailureStore.snapshot_status(now: DateTime.utc_now())
  end

  test "security regression: route key mismatch in store is malformed not a silent leak" do
    pid = Process.whereis(RouteFailureStore)
    assert is_pid(pid)
    now = DateTime.utc_now()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | routes: %{
            "openai_oauth" => %{
              route: "xai_oauth",
              class: :auth,
              code: "unauthorized",
              observed_at: now,
              expires_at: DateTime.add(now, 60, :second),
              retryable: false
            }
          }
      }
    end)

    try do
      assert {:error, :malformed} = RouteFailureStore.snapshot_status(now: now)
      assert Process.alive?(pid)
      assert Process.whereis(RouteFailureStore) == pid
    after
      heal_route_failure_store_state()
    end
  end

  test "record then immediate default assembly rejects only the exact affected route" do
    info =
      LLMError.classify(
        ResponsesFailure.exception(
          route: :openai_oauth,
          backend: :openai,
          code: :rate_limited,
          status: 429,
          retry_after_ms: 120_000
        )
      )

    assert {:ok, :recorded} = AI.record_classified_llm_failure(info)

    model_o = model_entry("mo", :openai_oauth)
    model_x = model_entry("mx", :xai_oauth)

    # Production default observation_reader — no injected evidence readers.
    assert {:ok, input} =
             RouteInputAssembler.assemble(
               profile: enabled_profile([model_o, model_x]),
               clock: fn -> @now end,
               budget_reader: fn providers, dt ->
                 {:ok, Enum.map(providers, &budget(&1, dt))}
               end
             )

    by_provider = Map.new(input.observations, &{&1.provider, &1})
    assert by_provider["openai_oauth"].quota_state == "exhausted"
    assert by_provider["openai_oauth"].availability == "unavailable"
    # xai may be unavailable from oauth_health login_required, but must not carry
    # openai's quota exhaustion evidence.
    refute by_provider["xai_oauth"].quota_state == "exhausted"
  end

  test "record then immediate default assembly rejects route-failure on exact route only" do
    info =
      LLMError.classify(
        ResponsesFailure.exception(
          route: :xai_oauth,
          backend: :xai,
          code: :xai_oauth_tier_denied,
          status: 403
        )
      )

    assert {:ok, :recorded} = AI.record_classified_llm_failure(info)

    model_o = model_entry("mo", :openai_oauth)
    model_x = model_entry("mx", :xai_oauth)

    assert {:ok, input} =
             RouteInputAssembler.assemble(
               profile: enabled_profile([model_o, model_x]),
               clock: fn -> DateTime.utc_now() end,
               budget_reader: fn providers, dt ->
                 {:ok, Enum.map(providers, &budget(&1, dt))}
               end
             )

    by_provider = Map.new(input.observations, &{&1.provider, &1})
    assert by_provider["xai_oauth"].failure_code == "tier_denied"
    assert by_provider["xai_oauth"].subscription_capacity_state == "exhausted"
    assert by_provider["xai_oauth"].availability == "unavailable"
    refute by_provider["openai_oauth"].failure_code == "tier_denied"
    refute by_provider["openai_oauth"].subscription_capacity_state == "exhausted"
  end

  test "security regression: default assembly fails closed when route-failure reader is unavailable" do
    assert is_pid(Process.whereis(RouteFailureStore))

    # Deterministic: terminate supervised child without auto-restart until restart_child.
    assert :ok = Supervisor.terminate_child(Arbor.AI.Supervisor, RouteFailureStore)
    assert Process.whereis(RouteFailureStore) == nil

    try do
      assert {:error, :unavailable} = RouteFailureStore.snapshot_status(now: @now)

      assert {:error, :unavailable} =
               RouteFailureStore.put_sync(
                 route: "openai_oauth",
                 class: :auth,
                 code: "unauthorized",
                 retryable: false
               )

      # No caller-owned lazy start while the supervised child is terminated.
      assert Process.whereis(RouteFailureStore) == nil

      model = model_entry("m1", :openai_oauth)

      # Production default observation_reader (no injected evidence readers).
      assert {:error, {:route_assembly_failed, :route_failure_evidence_unavailable}} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile([model]),
                 clock: fn -> @now end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget(&1, dt))}
                 end
               )

      assert Process.whereis(RouteFailureStore) == nil
    after
      ensure_route_failure_store_running()
    end
  end

  test "security regression: default assembly fails closed on malformed current store state" do
    pid = Process.whereis(RouteFailureStore)
    assert is_pid(pid)

    # Corrupt supervised in-memory state deterministically; production default reader
    # must fail closed with the typed malformed error without crashing the store.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | routes: %{
            "openai_oauth" => %{
              route: "openai_oauth",
              class: :auth,
              code: "unauthorized",
              observed_at: DateTime.utc_now(),
              expires_at: "not-a-datetime",
              retryable: false
            }
          }
      }
    end)

    try do
      assert Process.alive?(pid)
      assert {:error, :malformed} = RouteFailureStore.snapshot_status(now: DateTime.utc_now())
      assert Process.alive?(pid)
      assert Process.whereis(RouteFailureStore) == pid

      model = model_entry("m1", :openai_oauth)

      assert {:error, {:route_assembly_failed, :route_failure_evidence_malformed}} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile([model]),
                 clock: fn -> @now end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget(&1, dt))}
                 end
               )

      assert Process.alive?(pid)
      assert Process.whereis(RouteFailureStore) == pid
    after
      heal_route_failure_store_state()
    end
  end

  test "security regression: cleanup cannot erase corrupt required evidence into a clean route" do
    pid = Process.whereis(RouteFailureStore)
    assert is_pid(pid)
    now = DateTime.utc_now()

    # Inject corrupt required evidence (non-DateTime expires_at).
    :sys.replace_state(pid, fn state ->
      %{
        state
        | routes: %{
            "openai_oauth" => %{
              route: "openai_oauth",
              class: :auth,
              code: "unauthorized",
              observed_at: now,
              expires_at: "not-a-datetime",
              retryable: false
            }
          }
      }
    end)

    try do
      assert {:error, :malformed} = RouteFailureStore.snapshot_status(now: now)

      # Periodic cleanup must retain the corrupt slot (fail-closed), not drop it.
      send(pid, :cleanup)
      # Drain: cleanup is handle_info; a sync call waits for prior messages.
      assert {:error, :malformed} = RouteFailureStore.snapshot_status(now: now)
      assert Process.alive?(pid)
      assert Process.whereis(RouteFailureStore) == pid

      model = model_entry("m1", :openai_oauth)

      assert {:error, {:route_assembly_failed, :route_failure_evidence_malformed}} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile([model]),
                 clock: fn -> @now end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget(&1, dt))}
                 end
               )

      # Explicit recovery heals; only then is the route clean.
      heal_route_failure_store_state()
      assert {:ok, %{}} = RouteFailureStore.snapshot_status(now: DateTime.utc_now())
    after
      heal_route_failure_store_state()
    end
  end

  test "binary-or-atom closed code admission; malformed snapshot opts; map attrs bounded like keywords" do
    observed = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires = DateTime.add(observed, 60, :second)

    # Atom code admitted (existing closed atom only).
    assert :ok =
             RouteFailureStore.put_sync(
               route: "openai_oauth",
               class: :transport,
               code: :connection_failed,
               retryable: false,
               observed_at: observed,
               expires_at: expires
             )

    assert {:ok, %{"openai_oauth" => %{code: "connection_failed"}}} =
             RouteFailureStore.snapshot_status(now: observed)

    RouteFailureStore.clear_sync(:openai_oauth)

    # Binary code admitted (exact closed table membership).
    assert :ok =
             RouteFailureStore.put_sync(%{
               "route" => "openai_oauth",
               "class" => "auth",
               "code" => "unauthorized",
               "retryable" => false,
               "observed_at" => observed,
               "expires_at" => expires
             })

    assert {:ok, %{"openai_oauth" => %{class: :auth, code: "unauthorized", retryable: false}}} =
             RouteFailureStore.snapshot_status(now: observed)

    # Free-text / unknown codes rejected (no dynamic atom creation).
    assert {:error, :rejected} =
             RouteFailureStore.put_sync(
               route: "xai_oauth",
               class: :auth,
               code: "payment_declined",
               retryable: false,
               observed_at: observed,
               expires_at: expires
             )

    assert {:error, :rejected} =
             RouteFailureStore.put_sync(
               route: "xai_oauth",
               class: :auth,
               code: :not_a_closed_code,
               retryable: false,
               observed_at: observed,
               expires_at: expires
             )

    # Malformed snapshot options return {:error, :malformed}.
    assert {:error, :malformed} = RouteFailureStore.snapshot_status(%{now: observed})
    assert {:error, :malformed} = RouteFailureStore.snapshot_status("not-a-keyword-list")
    assert {:error, :malformed} = RouteFailureStore.snapshot_status(now: "not-a-datetime")

    # Map attrs share the keyword entry bound (64): oversized maps reject at the
    # public boundary and never enter the GenServer mailbox.
    pid = Process.whereis(RouteFailureStore)
    assert is_pid(pid)

    oversized =
      0..64
      |> Map.new(fn i -> {:"k#{i}", i} end)
      |> Map.merge(%{
        route: "xai_oauth",
        class: :auth,
        code: "unauthorized",
        retryable: false,
        observed_at: observed,
        expires_at: expires
      })

    assert map_size(oversized) > 64
    assert {:error, :rejected} = RouteFailureStore.put_sync(oversized)
    assert Process.alive?(pid)
    assert Process.whereis(RouteFailureStore) == pid
    assert {:ok, failures} = RouteFailureStore.snapshot_status(now: observed)
    refute Map.has_key?(failures, "xai_oauth")
  end

  test "write failure propagates when route-failure store is unavailable" do
    assert is_pid(Process.whereis(RouteFailureStore))
    assert :ok = Supervisor.terminate_child(Arbor.AI.Supervisor, RouteFailureStore)
    assert Process.whereis(RouteFailureStore) == nil

    try do
      info =
        LLMError.classify(
          ResponsesFailure.exception(
            route: :openai_oauth,
            backend: :openai,
            code: :unauthorized,
            status: 401
          )
        )

      assert {:error, :route_failure_write_failed} = AI.record_classified_llm_failure(info)
      # Public write boundary fails; store remains supervised-down (no lazy start).
      assert Process.whereis(RouteFailureStore) == nil
    after
      ensure_route_failure_store_running()
    end
  end

  test "oauth_route exact table used by health observation helper" do
    assert OAuthHealthObservation.oauth_route?("openai_oauth")
    refute OAuthHealthObservation.oauth_route?("openai")
  end

  defp ensure_route_failure_store_running do
    case Process.whereis(RouteFailureStore) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        case Supervisor.restart_child(Arbor.AI.Supervisor, RouteFailureStore) do
          {:ok, _pid} ->
            :ok

          {:ok, _pid, _info} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, :running} ->
            :ok

          other ->
            flunk("failed to restart RouteFailureStore: #{inspect(other)}")
        end
    end

    assert is_pid(Process.whereis(RouteFailureStore))
    RouteFailureStore.clear_sync(:openai_oauth)
    RouteFailureStore.clear_sync(:xai_oauth)
    :ok
  end

  defp heal_route_failure_store_state do
    ensure_route_failure_store_running()

    case Process.whereis(RouteFailureStore) do
      pid when is_pid(pid) ->
        :sys.replace_state(pid, fn state -> %{state | routes: %{}} end)
        :ok

      _ ->
        :ok
    end
  end

  defp base_obs(provider) do
    %{
      "version" => 1,
      "provider" => provider,
      "source" => "arbor_oauth_health",
      "runtime" => "arbor",
      "observed_at" => DateTime.to_iso8601(@now),
      "expires_at" => DateTime.to_iso8601(DateTime.add(@now, 30, :second)),
      "availability" => "available",
      "auth_health" => "healthy",
      "model_catalog_membership" => "unknown",
      "quota_state" => "unknown",
      "subscription_capacity_state" => "unknown"
    }
  end

  defp enabled_profile(catalog) do
    providers =
      catalog
      |> Enum.flat_map(fn m -> Enum.map(m.providers, &Atom.to_string(&1.id)) end)
      |> Enum.uniq()

    %{
      enabled: true,
      task_registry: %{"default" => %{requirements: %{}}},
      default_task_class: "default",
      catalog: catalog,
      scoreboard: [],
      providers: providers,
      params: %{}
    }
  end

  defp model_entry(id, provider) do
    %ModelEntry{
      canonical_id: id,
      providers: [%ProviderEntry{id: provider, ref: id, auth: :api_key, runtimes: [:arbor]}],
      family: :test,
      context_window: 100_000,
      max_output_tokens: 4_000
    }
  end

  defp budget(provider, %DateTime{} = dt) do
    %{
      "version" => 1,
      "provider" => provider,
      "source" => "arbor_ai_trackers",
      "observed_at" => DateTime.to_iso8601(dt),
      "expires_at" => DateTime.to_iso8601(DateTime.add(dt, 300, :second)),
      "current_spend" => 0.0,
      "request_count" => 0,
      "quota_state" => "available",
      "subscription_capacity_state" => "unknown"
    }
  end
end

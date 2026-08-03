defmodule Arbor.Security.DisclosureCapability do
  @moduledoc """
  Interactive-disclosure capability convention (VP-05D2A0, prerequisite for
  VOICE-17, which remains planned).

  Represents an authenticated human's decision to disclose one bounded turn
  to one external provider route. Reuses `Arbor.Contracts.Security.Capability`
  directly — no parallel signed grant type — under a distinct
  `arbor://egress/disclose/...` URI namespace, structurally separate from
  ordinary `constraints.egress` refinement (`Arbor.Security.EgressGate`).

  ## Invariants

  A disclosure capability is bound to exactly one `principal_id` (the
  executing agent), `session_id`, `task_id`, and authenticated-human
  `principal_scope` (`human_...`); has `delegation_depth: 0`, no
  `parent_capability_id`, an empty `delegation_chain`, and `max_uses: nil`
  (never capped — one bounded turn can require multiple LLM/tool waves); a
  short, config-bounded expiry; and a closed `constraints.disclosure` map
  (`kind: :interactive_human`, canonical `destination`/`provider`/`runtime`,
  `model` only when explicitly user-selected) with no other top-level or
  nested constraint keys.

  `issue/1` is the supported public issuance path — it owns URI construction (a fresh
  random token per grant, so two grants for the same route never collide
  under `CapabilityStore`'s principal+resource replace-on-put) and forces
  every invariant above regardless of caller input. `fetch_and_validate/2` is
  the only way to read one back — it accepts an exact capability id (never a
  caller-supplied struct, never a covering-cap search) and revalidates it
  against the live request before returning it.

  Route and binding fields (`destination`, `provider`, `runtime`, `model`,
  `session_id`, `task_id`, `principal_scope`, `principal_id`, and the
  capability id itself) must satisfy a closed canonical grammar: non-empty,
  valid UTF-8, free of control characters, not padded with leading/trailing
  whitespace, and bounded in length. `destination`, `provider`, and `model`
  are the caller's exact selected catalog/provider route identity — Arbor's
  live provider/model catalog is owned by `arbor_llm`/`arbor_ai` (both above
  `arbor_security` in the dependency hierarchy), so this module does not — and
  structurally cannot — validate `provider` against a fixed allowlist; any
  well-formed canonical string is accepted. `runtime` is the one closed axis:
  it must be Arbor's own source-owned runtime axis, exactly `"arbor"`
  (in-BEAM/`arbor_llm`) or `"acp"` (subprocess/ACP) — see
  `Arbor.AI.Runtime`'s moduledoc for the two real runtimes.

  Every function that receives caller-supplied `opts` checks
  `Keyword.keyword?/1` before any `Keyword` access, and every malformed
  option/constraint/route field, and every signer/store-unavailable path,
  returns `{:error, _}` rather than raising, exiting, or falling back to
  `:allow`.

  Out of scope for this module: issuing disclosure authority from
  message/model fields, carrying it through Engine context, or wiring
  Agent/Voice ingress — those are later VP-05D2A1/A2/B/C packets.
  """

  alias Arbor.Contracts.Security.{Capability, CapabilityUri}
  alias Arbor.Identifiers
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Config
  alias Arbor.Security.Events
  alias Arbor.Security.SystemAuthority

  @disclosure_uri_prefix "arbor://egress/disclose"
  @kind :interactive_human

  # Arbor's source-owned runtime axis (Arbor.AI.Runtime): `:arbor` is the
  # in-BEAM loop through arbor_llm; `:acp` is the subprocess/ACP path. This is
  # a structural property of Arbor's own execution model, not deployment
  # policy — deliberately NOT an operator-configurable allowlist, and
  # deliberately NOT the invented cloud/edge/local labels an earlier attempt
  # used.
  @accepted_runtimes ["arbor", "acp"]
  @provider_route_id ~r/\A[a-z0-9][a-z0-9_.:-]*\z/

  @known_issue_keys [
    :principal_id,
    :session_id,
    :task_id,
    :principal_scope,
    :destination,
    :provider,
    :runtime,
    :model,
    :ttl_seconds
  ]

  @known_disclosure_pairs [
    {:kind, "kind"},
    {:destination, "destination"},
    {:provider, "provider"},
    {:runtime, "runtime"},
    {:model, "model"}
  ]

  @max_binding_field_bytes 256
  @max_capability_id_bytes 128

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Mint a new disclosure capability. Facade-owned issuance — see
  `Arbor.Security.issue_disclosure_capability/1` for the public entrypoint.

  Required opts: `:principal_id`, `:session_id`, `:task_id`, `:principal_scope`
  (must start with `\"human_\"`), `:destination` and `:provider` (the exact
  selected catalog/provider route identity — any well-formed canonical
  string, no fixed allowlist), `:runtime` (must be exactly `"arbor"` or
  `"acp"`). Optional: `:model`, `:ttl_seconds` (positive integer, capped at
  `Config.disclosure_capability_max_ttl_seconds/0`, defaults to that same
  cap). Any other opt key, a duplicate key, a non-keyword-list `opts`, or a
  non-positive/non-integer `:ttl_seconds` is rejected.

  `delegation_depth: 0` and `max_uses: nil` are forced unconditionally —
  there is no opt to override either.
  """
  @spec issue(keyword()) :: {:ok, Capability.t()} | {:error, atom()}
  def issue(opts) do
    with :ok <- validate_known_opts(opts),
         {:ok, fields} <- extract_and_validate_fields(opts),
         {:ok, cap} <- build_capability(fields),
         {:ok, signed_cap} <- safe_sign(cap),
         {:ok, :stored} <- safe_put(signed_cap) do
      Events.record_capability_granted(signed_cap)
      {:ok, signed_cap}
    end
  end

  @doc """
  Fetch an exact disclosure capability by id and revalidate it against the
  live request. Never accepts a caller-supplied capability struct and never
  searches for a broad covering disclosure capability — `capability_id` must
  be the exact id.

  `opts`: `:principal_id` (required, the executing agent), `:session_id`,
  `:task_id`, `:principal_scope` (the authenticated human), `:egress_destination`,
  `:egress_provider`, `:egress_runtime`, `:egress_model` (the route being
  requested). Every failure mode — forged/unsigned/expired/wrong-principal/
  wrong-session/wrong-task/wrong-human/delegated/revoked/malformed/wrong-route —
  fails closed to an `{:error, atom}`. Grammar, delegation-shape (parent/chain/
  depth/max_uses), constraint-schema, and route-match failures return a
  specific atom for each; current/stored/signature/chain/scope failures are
  checked together inside one linearized `CapabilityStore.get_valid_disclosure/3`
  call and collapse to the single `:disclosure_capability_rejected` atom —
  callers only need to fail closed on `{:error, _}`, never on a specific atom.
  """
  @spec fetch_and_validate(term(), term()) :: {:ok, Capability.t()} | {:error, atom()}
  def fetch_and_validate(capability_id, opts) do
    if Keyword.keyword?(opts) do
      do_fetch_and_validate(capability_id, opts)
    else
      {:error, :invalid_fetch_opts}
    end
  end

  defp do_fetch_and_validate(capability_id, opts) do
    principal_id = Keyword.get(opts, :principal_id)

    with :ok <- validate_capability_id(capability_id),
         :ok <- validate_principal_id_present(principal_id),
         {:ok, scope_context} <- validate_scope_fields(opts),
         {:ok, route} <- validate_route_fields(opts),
         {:ok, cap} <-
           CapabilityStore.get_valid_disclosure(capability_id, principal_id, scope_context),
         :ok <- validate_shape(cap),
         :ok <- validate_route_match(cap, route) do
      {:ok, cap}
    end
  end

  # ===========================================================================
  # Issuance — opts validation
  # ===========================================================================

  defp validate_known_opts(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        keys -- Enum.uniq(keys) != [] -> {:error, :duplicate_issue_option}
        keys -- @known_issue_keys != [] -> {:error, :unknown_issue_option}
        true -> :ok
      end
    else
      {:error, :invalid_issue_opts}
    end
  end

  defp extract_and_validate_fields(opts) do
    with {:ok, principal_id} <- required_agent_field(opts),
         {:ok, session_id} <- required_field(opts, :session_id, :invalid_binding_field),
         {:ok, task_id} <- required_field(opts, :task_id, :invalid_binding_field),
         {:ok, principal_scope} <- required_human_field(opts),
         {:ok, destination} <- required_field(opts, :destination, :invalid_destination),
         {:ok, provider} <- required_provider_field(opts),
         {:ok, runtime} <-
           required_label_field(opts, :runtime, @accepted_runtimes, :invalid_runtime),
         {:ok, model} <- optional_field(opts, :model, :invalid_model),
         {:ok, ttl} <- validate_ttl(opts) do
      {:ok,
       %{
         principal_id: principal_id,
         session_id: session_id,
         task_id: task_id,
         principal_scope: principal_scope,
         destination: destination,
         provider: provider,
         runtime: runtime,
         model: model,
         ttl_seconds: ttl
       }}
    end
  end

  defp required_field(opts, key, error) do
    value = Keyword.get(opts, key)
    max_bytes = route_field_max_bytes_for(key)

    if canonical_field?(value, max_bytes), do: {:ok, value}, else: {:error, error}
  end

  defp required_agent_field(opts) do
    value = Keyword.get(opts, :principal_id)

    if canonical_field?(value, @max_binding_field_bytes) and
         Identifiers.valid_id?(value, :agent) do
      {:ok, value}
    else
      {:error, :invalid_binding_field}
    end
  end

  defp required_provider_field(opts) do
    value = Keyword.get(opts, :provider)
    max_bytes = Config.disclosure_capability_route_field_max_bytes()

    if canonical_provider?(value, max_bytes),
      do: {:ok, value},
      else: {:error, :invalid_provider}
  end

  defp route_field_max_bytes_for(key) when key in [:destination, :provider, :model],
    do: Config.disclosure_capability_route_field_max_bytes()

  defp route_field_max_bytes_for(_key), do: @max_binding_field_bytes

  defp required_human_field(opts) do
    value = Keyword.get(opts, :principal_scope)

    if canonical_human_principal?(value) do
      {:ok, value}
    else
      {:error, :invalid_binding_field}
    end
  end

  defp required_label_field(opts, key, accepted, error) do
    value = Keyword.get(opts, key)
    max_bytes = Config.disclosure_capability_route_field_max_bytes()

    if canonical_field?(value, max_bytes) and accepted_label?(value, accepted) do
      {:ok, value}
    else
      {:error, error}
    end
  end

  defp optional_field(opts, key, error) do
    case Keyword.get(opts, key) do
      nil ->
        {:ok, nil}

      value ->
        if canonical_field?(value, Config.disclosure_capability_route_field_max_bytes()),
          do: {:ok, value},
          else: {:error, error}
    end
  end

  defp validate_ttl(opts) do
    case Keyword.get(opts, :ttl_seconds) do
      nil ->
        {:ok, Config.disclosure_capability_max_ttl_seconds()}

      ttl when is_integer(ttl) and ttl > 0 ->
        {:ok, min(ttl, Config.disclosure_capability_max_ttl_seconds())}

      _invalid ->
        {:error, :invalid_ttl}
    end
  end

  defp build_capability(fields) do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    resource_uri = @disclosure_uri_prefix <> "/" <> token
    now = DateTime.utc_now()

    disclosure_constraints =
      %{
        kind: @kind,
        destination: fields.destination,
        provider: fields.provider,
        runtime: fields.runtime
      }
      |> maybe_put_model(fields.model)

    Capability.new(
      resource_uri: resource_uri,
      principal_id: fields.principal_id,
      granted_at: now,
      session_id: fields.session_id,
      task_id: fields.task_id,
      principal_scope: fields.principal_scope,
      delegation_depth: 0,
      max_uses: nil,
      expires_at: DateTime.add(now, fields.ttl_seconds, :second),
      constraints: %{disclosure: disclosure_constraints}
    )
  end

  defp maybe_put_model(map, nil), do: map
  defp maybe_put_model(map, model), do: Map.put(map, :model, model)

  # Missing-authority/missing-store containment: neither SystemAuthority.sign_capability/1
  # nor CapabilityStore.put/1 wraps GenServer.call itself, so a dead/unregistered
  # target process would otherwise exit past this function and crash the caller.
  defp safe_sign(cap) do
    SystemAuthority.sign_capability(cap)
  rescue
    _ -> {:error, :system_authority_unavailable}
  catch
    :exit, _ -> {:error, :system_authority_unavailable}
    :throw, _ -> {:error, :system_authority_unavailable}
  end

  defp safe_put(cap) do
    CapabilityStore.put(cap)
  rescue
    _ -> {:error, :capability_store_unavailable}
  catch
    :exit, _ -> {:error, :capability_store_unavailable}
    :throw, _ -> {:error, :capability_store_unavailable}
  end

  # ===========================================================================
  # Read-time validation
  # ===========================================================================

  @doc false
  @spec valid_capability_id?(term()) :: boolean()
  def valid_capability_id?(id) when is_binary(id) do
    canonical_field?(id, @max_capability_id_bytes) and
      Identifiers.valid_id?(id, :capability)
  end

  def valid_capability_id?(_id), do: false

  defp validate_capability_id(id) do
    if valid_capability_id?(id),
      do: :ok,
      else: {:error, :disclosure_capability_id_malformed}
  end

  defp validate_principal_id_present(id) when is_binary(id) do
    if canonical_field?(id, @max_binding_field_bytes) and Identifiers.valid_id?(id, :agent),
      do: :ok,
      else: {:error, :disclosure_capability_wrong_principal}
  end

  defp validate_principal_id_present(_id), do: {:error, :disclosure_capability_wrong_principal}

  defp validate_scope_fields(opts) do
    with {:ok, session_id} <-
           validate_binding_field(
             Keyword.get(opts, :session_id),
             :disclosure_capability_wrong_session
           ),
         {:ok, task_id} <-
           validate_binding_field(Keyword.get(opts, :task_id), :disclosure_capability_wrong_task),
         {:ok, principal_scope} <-
           validate_human_scope_request(Keyword.get(opts, :principal_scope)) do
      {:ok, [session_id: session_id, task_id: task_id, principal_scope: principal_scope]}
    end
  end

  defp validate_binding_field(value, error) do
    if canonical_field?(value, @max_binding_field_bytes), do: {:ok, value}, else: {:error, error}
  end

  defp validate_human_scope_request(value) do
    if canonical_human_principal?(value) do
      {:ok, value}
    else
      {:error, :disclosure_capability_wrong_human}
    end
  end

  defp validate_route_fields(opts) do
    destination = Keyword.get(opts, :egress_destination)
    provider = Keyword.get(opts, :egress_provider)
    runtime = Keyword.get(opts, :egress_runtime)
    model = Keyword.get(opts, :egress_model)
    max_bytes = Config.disclosure_capability_route_field_max_bytes()

    cond do
      not canonical_field?(destination, max_bytes) ->
        {:error, :disclosure_capability_wrong_route}

      not canonical_provider?(provider, max_bytes) ->
        {:error, :disclosure_capability_wrong_route}

      not (canonical_field?(runtime, max_bytes) and accepted_label?(runtime, @accepted_runtimes)) ->
        {:error, :disclosure_capability_wrong_route}

      not is_nil(model) and not canonical_field?(model, max_bytes) ->
        {:error, :disclosure_capability_wrong_route}

      true ->
        {:ok, %{destination: destination, provider: provider, runtime: runtime, model: model}}
    end
  end

  defp validate_shape(%Capability{} = cap) do
    now = DateTime.utc_now()

    cond do
      not exact_disclosure_uri?(cap.resource_uri) ->
        {:error, :disclosure_capability_uri_malformed}

      cap.parent_capability_id != nil or cap.delegation_chain != [] ->
        {:error, :disclosure_capability_delegated}

      cap.delegation_depth != 0 ->
        {:error, :disclosure_capability_nonzero_depth}

      cap.max_uses != nil ->
        {:error, :disclosure_capability_max_uses_forbidden}

      true ->
        with :ok <- validate_temporal_shape(cap, now) do
          validate_constraints_shape(cap.constraints)
        end
    end
  end

  defp validate_temporal_shape(
         %Capability{granted_at: %DateTime{} = granted_at, expires_at: %DateTime{} = expires_at},
         %DateTime{} = now
       ) do
    max_ttl = Config.disclosure_capability_max_ttl_seconds()
    validity_seconds = DateTime.diff(expires_at, granted_at, :second)
    remaining_seconds = DateTime.diff(expires_at, now, :second)

    cond do
      DateTime.compare(granted_at, now) == :gt ->
        {:error, :disclosure_capability_future_grant}

      validity_seconds <= 0 ->
        {:error, :disclosure_capability_invalid_window}

      validity_seconds > max_ttl or remaining_seconds > max_ttl ->
        {:error, :disclosure_capability_expiry_too_long}

      true ->
        :ok
    end
  end

  defp validate_temporal_shape(%Capability{expires_at: nil}, _now),
    do: {:error, :disclosure_capability_missing_expiry}

  defp validate_temporal_shape(_cap, _now),
    do: {:error, :disclosure_capability_invalid_window}

  defp validate_constraints_shape(constraints) when is_map(constraints) do
    top_level_recognized = count_recognized(constraints, [{:disclosure, "disclosure"}])

    if map_size(constraints) > top_level_recognized do
      {:error, :disclosure_capability_dual_purpose}
    else
      case get_field(constraints, :disclosure) do
        %{} = disclosure -> validate_disclosure_map(disclosure)
        _ -> {:error, :disclosure_capability_missing_constraints}
      end
    end
  end

  defp validate_constraints_shape(_constraints),
    do: {:error, :disclosure_capability_missing_constraints}

  defp validate_disclosure_map(map) do
    recognized = count_recognized(map, @known_disclosure_pairs)
    max_bytes = Config.disclosure_capability_route_field_max_bytes()

    cond do
      map_size(map) > recognized ->
        {:error, :disclosure_capability_unknown_field}

      normalize_kind(get_field(map, :kind)) != @kind ->
        {:error, :disclosure_capability_wrong_kind}

      not canonical_field?(get_field(map, :destination), max_bytes) ->
        {:error, :disclosure_capability_missing_route_field}

      not canonical_provider?(get_field(map, :provider), max_bytes) ->
        {:error, :disclosure_capability_missing_route_field}

      not (canonical_field?(get_field(map, :runtime), max_bytes) and
               accepted_label?(get_field(map, :runtime), @accepted_runtimes)) ->
        {:error, :disclosure_capability_missing_route_field}

      has_field?(map, :model) and not canonical_field?(get_field(map, :model), max_bytes) ->
        {:error, :disclosure_capability_missing_route_field}

      true ->
        :ok
    end
  end

  defp validate_route_match(cap, route) do
    disclosure = get_field(cap.constraints, :disclosure) || %{}

    cond do
      get_field(disclosure, :destination) != route.destination ->
        {:error, :disclosure_capability_wrong_route}

      get_field(disclosure, :provider) != route.provider ->
        {:error, :disclosure_capability_wrong_route}

      get_field(disclosure, :runtime) != route.runtime ->
        {:error, :disclosure_capability_wrong_route}

      has_field?(disclosure, :model) and get_field(disclosure, :model) != route.model ->
        {:error, :disclosure_capability_wrong_route}

      true ->
        :ok
    end
  end

  defp count_recognized(map, pairs) do
    Enum.count(pairs, fn {a, s} -> Map.has_key?(map, a) or Map.has_key?(map, s) end)
  end

  defp get_field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp get_field(_map, _key), do: nil

  defp has_field?(map, key) when is_map(map) and is_atom(key),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp has_field?(_map, _key), do: false

  defp normalize_kind(:interactive_human), do: :interactive_human
  defp normalize_kind("interactive_human"), do: :interactive_human
  defp normalize_kind(_other), do: nil

  # ===========================================================================
  # Closed canonical grammar
  # ===========================================================================

  defp canonical_field?(value, max_bytes) when is_binary(value) do
    byte_size(value) > 0 and byte_size(value) <= max_bytes and
      String.valid?(value) and String.trim(value) == value and not control_chars?(value)
  end

  defp canonical_field?(_value, _max_bytes), do: false

  defp canonical_provider?(value, max_bytes) do
    canonical_field?(value, max_bytes) and Regex.match?(@provider_route_id, value)
  end

  defp canonical_human_principal?(value) do
    canonical_field?(value, @max_binding_field_bytes) and
      String.starts_with?(value, "human_") and value != "human_"
  end

  defp exact_disclosure_uri?(uri) do
    case CapabilityUri.parse(uri) do
      {:ok, %{segments: ["egress", "disclose", token], wildcard: :none} = parsed} ->
        CapabilityUri.canonical(parsed) == uri and byte_size(token) == 32 and
          String.match?(token, ~r/\A[0-9a-f]{32}\z/)

      _ ->
        false
    end
  end

  defp control_chars?(value) do
    value
    |> String.to_charlist()
    |> Enum.any?(&(&1 < 0x20 or &1 == 0x7F))
  end

  defp accepted_label?(value, accepted) when is_list(accepted) do
    is_binary(value) and value in accepted
  end
end

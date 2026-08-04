defmodule Arbor.AI.Runtime.Dispatch do
  @behaviour Arbor.LLM.Dispatcher

  @moduledoc """
  High-level dispatch surface that bridges model resolution → runtime
  selection → LLM call.

  After Phase 2c this does four things:

    1. Resolves `request.model` to a `%ModelEntry{}` via
       `Arbor.Common.ModelProfile.entry/1` (which reads llm_db).
    2. Picks `{provider, runtime}` via `Arbor.AI.Runtime.Selector.choose/2`.
    3. Emits a `[:arbor, :runtime, :selected]` telemetry event with the
       chosen tuple.
    4. Sets `request.provider` and `request.runtime` to the selection,
       then dispatches through `Arbor.AI.Runtime.Registry.lookup/1` —
       the chosen runtime adapter's `execute/3` runs the turn.

  In Phase 2b this function forwarded to `Arbor.LLM.Client.complete/3`
  directly because adapter modules didn't exist yet (the runtime atom
  was observable but not load-bearing). Phase 2c made the runtime atom
  load-bearing by adding `:runtime` to `Arbor.LLM.Request`, shipping
  `Runtime.Arbor` and `Runtime.Acp`, and routing dispatch through the
  registry.

  ## Backwards compat for direct Client.complete callers

  `Arbor.LLM.Client.complete/3` is still the low-level entry point and
  works unchanged — Request's `:runtime` field defaults to `:arbor`,
  and `Client.complete`'s provider-based adapter dispatch handles every
  case it did before. The existing `Arbor.AI.LLM.Adapter.Acp` is now
  `@deprecated` (callers should use `Dispatch.dispatch/2`) but keeps
  working through the same provider-string dispatch path.
  """

  require Logger

  alias Arbor.AI.RouteConcurrency
  alias Arbor.AI.Runtime.Acp, as: RuntimeAcp
  alias Arbor.AI.Runtime.ProviderRouter
  alias Arbor.AI.Runtime.Registry, as: RuntimeRegistry
  alias Arbor.AI.Runtime.RoutePlan
  alias Arbor.AI.Runtime.Selector
  alias Arbor.Common.ModelProfile
  alias Arbor.Contracts.LLM.{ModelEntry, ProviderEntry}
  alias Arbor.LLM.Client
  alias Arbor.LLM.FallbackLoop
  alias Arbor.LLM.Request
  alias Arbor.LLM.Response

  # Arbor-owned executed-route evidence lives on Response.usage only.
  # Response.raw is untrusted provider payload and must never carry this key.
  @executed_route_key "arbor.executed_route"
  @executed_route_aliases [
    "arbor.executed_route",
    "arbor_executed_route",
    :arbor_executed_route,
    :"arbor.executed_route"
  ]
  # Private attribution for ReqLLM Usage — never forwarded to non-Arbor runtimes.
  @private_usage_opt :provider_usage_context
  @max_authorization_route_text_bytes 512

  @type authorization_route :: %{
          model_entry: ModelEntry.t(),
          provider: ProviderEntry.t(),
          runtime: atom(),
          destination: String.t(),
          model: String.t()
        }

  @type dispatch_opts :: [
          client: Client.t() | nil,
          policy: Selector.policy(),
          telemetry_metadata: map(),
          provider_route_input: ProviderRouter.input(),
          route_authorizer: (authorization_route() -> term())
        ]

  @doc """
  Resolve a request through the runtime selection chain and dispatch it
  through the chosen `Arbor.AI.Runtime` adapter.

  ## Options

    * `:policy` — `Arbor.AI.Runtime.Selector.policy()` map carrying per-
      turn override / model pins / default runtime. Defaults to `%{}`.
    * `:telemetry_metadata` — extra fields merged into the telemetry
      event metadata (request_id, agent_id, etc.). Defaults to `%{}`.
    * `:callbacks` — `Arbor.AI.Runtime.callbacks()` for streaming
      updates. Forwarded to the chosen runtime's `execute/3`.
    * `:client` — only used when the chosen runtime is `:arbor`; passes
      through to `Runtime.Arbor.execute/3` as an injectable `%Client{}`.
    * `:provider_route_input` — explicitly opts this call into
      `ProviderRouter` mode. The input must include the caller's catalog
      structs. Once present, selection never falls back to `Selector`.
    * `:route_authorizer` — process-local callback invoked with each exact
      source-owned route before runtime preparation or execution. The route keeps
      its `%{model_entry, provider, runtime}` selection metadata and adds the exact
      wire `:destination` (provider string) and `:model` that the runtime will
      receive. Only `:allow` admits the attempt. **Required** in ProviderRouter
      mode; **optional** in legacy Selector mode (absent preserves current
      behavior).

  Any other keys in `opts` are forwarded as runtime opts to the chosen
  runtime's `prepare/2` and `execute/3`.

  ## Fallback chains

    * `policy.fallback_chain` (Phase 4+) — ordered list of override maps
      tried in sequence when the primary attempt fails with a
      fallback-eligible error. Each entry can override `:runtime`,
      `:provider`, and/or `:model`; omitted fields inherit from the
      original request/policy.

    * Eligibility (`fallback_eligible?/1` below) covers both transient
      runtime failures (the `Arbor.LLM.Retry` shape: rate-limit, timeout,
      5xx, `%ProviderError{retryable: true}`) and declarative path
      failures (`:no_cli_for_provider`, `:no_provider_supports_runtime`,
      `:pool_not_available`, `:pool_exhausted`, `{:pool_exit, _}`,
      `{:session_exit, _}`, `{:selection_failed, _}`). Auth, bad-prompt,
      and non-retryable provider errors propagate immediately.

    * Each fallback attempt emits `[:arbor, :runtime, :fallback]`
      telemetry alongside the per-attempt `[:arbor, :runtime, :selected]`
      event so observability captures which path was taken and why.

  ## Errors

    * Selector errors propagate as `{:error, {:selection_failed, reason}}`.
    * Runtime errors propagate as `{:error, reason}` from the chosen
      `Runtime.<atom>.execute/3`.

  ## Execution path

  After selection, dispatch routes through the runtime registry:

      runtime_module = Arbor.AI.Runtime.Registry.lookup(selection.runtime)
      {:ok, prepared} = runtime_module.prepare(rewritten_request, runtime_opts)
      runtime_module.execute(prepared, callbacks, runtime_opts)

  `Runtime.Arbor.execute/3` delegates to `Client.complete/3` for the
  BEAM-native path. `Runtime.Acp.execute/3` talks to AcpPool directly.
  The `:client` opt is only consulted when the chosen runtime is
  `:arbor` — it's a hint passed through to `Runtime.Arbor`.
  """
  @impl Arbor.LLM.Dispatcher
  @spec dispatch(Request.t(), dispatch_opts()) :: {:ok, Response.t()} | {:error, term()}
  def dispatch(%Request{} = request, opts \\ []) do
    if Keyword.has_key?(opts, :provider_route_input) do
      dispatch_provider_route(request, opts)
    else
      dispatch_legacy(request, opts)
    end
  end

  defp dispatch_legacy(%Request{} = request, opts) do
    policy = Keyword.get(opts, :policy, %{})
    fallback_chain = Map.get(policy, :fallback_chain, [])
    base_policy = Map.delete(policy, :fallback_chain)

    initial_attempt = %{request: request, policy: base_policy, opts: opts}

    FallbackLoop.run(initial_attempt, fallback_chain,
      do_call: &dispatch_attempt/1,
      apply_override: &apply_dispatch_override/2,
      eligible?: &fallback_eligible?/1,
      on_fallback: &emit_fallback/3
    )
  end

  defp dispatch_provider_route(%Request{} = request, opts) do
    route_input = Keyword.fetch!(opts, :provider_route_input)

    case RoutePlan.build(route_input) do
      {:ok, plan} -> run_route_plan(request, plan, opts)
      {:error, reason} -> {:error, {:selection_failed, {:provider_route, reason}}}
    end
  end

  defp run_route_plan(request, %RoutePlan{} = plan, opts) do
    initial_attempt = %{request: request, route: plan.primary, opts: opts, attempt: :primary}

    case dispatch_route_attempt(initial_attempt) do
      {:ok, _response} = success ->
        success

      {:error, reason} = error ->
        if plan.fallbacks != [] and fallback_eligible?(reason) do
          run_route_fallbacks(request, plan.fallbacks, opts, error)
        else
          error
        end
    end
  end

  defp run_route_fallbacks(_request, [], _opts, last_error), do: last_error

  defp run_route_fallbacks(request, [route | rest], opts, last_error) do
    attempt = %{
      request: request,
      route: route,
      opts: opts,
      attempt: :fallback,
      fallback_from: last_error
    }

    case dispatch_route_attempt(attempt) do
      {:ok, _response} = success ->
        success

      {:error, reason} = error ->
        if rest != [] and fallback_eligible?(reason) do
          run_route_fallbacks(request, rest, opts, error)
        else
          error
        end
    end
  end

  defp dispatch_route_attempt(%{request: request, route: route, opts: opts} = attempt) do
    # Bind exact source-owned destination (including acp:<agent>) before authorize
    # and before concurrency/prepare/execute I/O.
    with {:ok, bound_route} <- bind_authorization_destination(route),
         :ok <- authorize_route(Keyword.get(opts, :route_authorizer), bound_route),
         {:ok, lease} <- acquire_route_concurrency(bound_route, opts) do
      try do
        run_authorized_route_attempt(attempt, request, bound_route, opts)
      after
        # Always release (success, error, raise, throw) before any fallback attempt.
        # Lease is bound to the exact authority server used for acquire.
        safe_release_lease(lease)
      end
    end
  end

  # Cleanup must never raise or replace the original runtime result.
  defp safe_release_lease(lease) do
    RouteConcurrency.release(lease)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp run_authorized_route_attempt(attempt, request, route, opts) do
    extra_meta = Keyword.get(opts, :telemetry_metadata, %{})
    callbacks = Keyword.get(opts, :callbacks, %{})
    selection = %{provider: route.provider, runtime: route.runtime}

    with :ok <- maybe_emit_route_fallback(attempt, route),
         :ok <-
           emit_selected(route.model_entry, selection, request, route_extra_meta(extra_meta)),
         {:ok, runtime_module} <- exact_runtime_module(route.runtime),
         rewritten <- rewrite_routed_request(request, route),
         runtime_opts <- runtime_opts_for(route.runtime, opts),
         {:ok, prepared} <- runtime_module.prepare(rewritten, runtime_opts),
         {:ok, %Response{} = response} <-
           execute_routed_runtime(runtime_module, prepared, callbacks, runtime_opts) do
      provider_confirmed = provider_confirmed?(response, route)
      :ok = emit_executed(route, request, attempt.attempt, provider_confirmed)
      {:ok, put_executed_route(response, route, attempt.attempt, provider_confirmed)}
    end
  end

  # Node-local exact-route admission. Leases never enter route input / JSON.
  defp acquire_route_concurrency(route, opts) do
    provider = route_provider_id(route)
    runtime = route.runtime
    server_opts = concurrency_server_opts(opts)

    case RouteConcurrency.acquire(provider, runtime, server_opts) do
      {:ok, lease} ->
        {:ok, lease}

      {:error, reason}
      when reason in [:at_capacity, :unconfigured_route, :malformed_route, :unavailable] ->
        {:error, {:route_concurrency, reason}}

      _ ->
        {:error, {:route_concurrency, :unavailable}}
    end
  end

  defp route_provider_id(%{provider: %{id: id}}), do: id
  defp route_provider_id(%{provider: id}) when is_atom(id) or is_binary(id), do: id
  defp route_provider_id(_), do: nil

  defp concurrency_server_opts(opts) when is_list(opts) do
    case Keyword.fetch(opts, :route_concurrency_server) do
      {:ok, server} -> [route_concurrency_server: server]
      :error -> []
    end
  end

  # Behaviour violations must fail closed — never return an unstamped success.
  defp execute_routed_runtime(runtime_module, prepared, callbacks, runtime_opts) do
    case runtime_module.execute(prepared, callbacks, runtime_opts) do
      {:ok, %Response{} = response} ->
        {:ok, response}

      {:ok, _not_response} ->
        {:error, {:selection_failed, {:provider_route, :invalid_runtime_response}}}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, {:selection_failed, {:provider_route, :invalid_runtime_response}}}
    end
  end

  defp maybe_emit_route_fallback(%{fallback_from: last_error} = attempt, route) do
    emit_route_fallback(attempt, route, last_error)
  end

  defp maybe_emit_route_fallback(_attempt, _route), do: :ok

  # Router mode: authorizer is required. Presence policy only — result
  # normalization is shared with legacy via invoke_route_authorizer/2.
  defp authorize_route(authorizer, route) when is_function(authorizer, 1) do
    authorize_exact_route(authorizer, route)
  end

  defp authorize_route(nil, _route),
    do: {:error, {:authorization_failed, :route_authorizer_required}}

  defp authorize_route(_authorizer, _route),
    do: {:error, {:authorization_failed, :invalid_route_authorizer}}

  # Legacy mode: authorizer is optional (absent = admit). Present non-fun fails closed.
  defp authorize_legacy_route(:error, _route), do: :ok

  defp authorize_legacy_route({:ok, authorizer}, route) when is_function(authorizer, 1) do
    authorize_exact_route(authorizer, route)
  end

  defp authorize_legacy_route({:ok, _invalid}, _route),
    do: {:error, {:authorization_failed, :invalid_route_authorizer}}

  defp authorize_exact_route(authorizer, route) do
    with {:ok, exact_route} <- normalize_authorization_route(route) do
      invoke_route_authorizer(authorizer, exact_route)
    else
      _ -> {:error, {:authorization_failed, :invalid_route}}
    end
  end

  # The rich catalog structs remain available for existing policy callbacks, but
  # authorization binds these two scalar fields because they are what runtime I/O
  # actually receives. Legacy synthesized entries cannot otherwise distinguish an
  # `openai` request from an `xai` request: both have provider id `:legacy`.
  # ACP runtime routes must already carry destination = "acp:<agent>" from the
  # shared Runtime.Acp resolver (bind_authorization_destination/1).
  defp normalize_authorization_route(
         %{
           model_entry: %ModelEntry{},
           provider: %ProviderEntry{id: provider_id} = provider,
           runtime: runtime
         } = route
       )
       when is_atom(provider_id) and provider_id not in [nil, true, false] and is_atom(runtime) and
              runtime not in [nil, true, false] do
    destination = Map.get(route, :destination, Atom.to_string(provider_id))
    model = Map.get(route, :model, provider.ref)

    if valid_authorization_route_text?(destination) and valid_authorization_route_text?(model) do
      {:ok, Map.merge(route, %{destination: destination, model: model})}
    else
      {:error, :invalid_route}
    end
  end

  defp normalize_authorization_route(_route), do: {:error, :invalid_route}

  # Bind exact wire destination shared by authorization and checkout.
  # Non-ACP: provider string. ACP: "acp:<cli>" via Runtime.Acp (single source).
  defp bind_authorization_destination(
         %{
           provider: %ProviderEntry{id: provider_id} = provider,
           runtime: runtime
         } = route
       )
       when is_atom(provider_id) and is_atom(runtime) do
    model = Map.get(route, :model, provider.ref)

    # Prefer rewritten request provider (legacy destination) for CLI lookup;
    # fall back to catalog provider id. Never treat an already-bound acp:* as a
    # provider name.
    provider_for_cli =
      case Map.get(route, :destination) do
        "acp:" <> _already -> Atom.to_string(provider_id)
        dest when is_binary(dest) and dest != "" -> dest
        _ -> Atom.to_string(provider_id)
      end

    case runtime do
      :acp ->
        case RuntimeAcp.authorization_destination(:acp, provider_for_cli) do
          {:ok, destination} ->
            if valid_authorization_route_text?(destination) and
                 valid_authorization_route_text?(model) do
              {:ok, Map.merge(route, %{destination: destination, model: model})}
            else
              {:error, {:authorization_failed, :invalid_route}}
            end

          {:error, _} ->
            {:error, {:authorization_failed, :invalid_route}}
        end

      _other ->
        destination =
          case Map.get(route, :destination) do
            dest when is_binary(dest) and dest != "" -> dest
            # The synthesized `:legacy` provider has no catalog identity of its
            # own — its destination is only ever the caller's rewritten request
            # provider. A missing destination here means the outbound identity
            # never resolved; the atom name "legacy" is not a real destination
            # and must not be admitted as one.
            _ when provider_id == :legacy -> nil
            _ -> Atom.to_string(provider_id)
          end

        if valid_authorization_route_text?(destination) and
             valid_authorization_route_text?(model) do
          {:ok, Map.merge(route, %{destination: destination, model: model})}
        else
          {:error, {:authorization_failed, :invalid_route}}
        end
    end
  end

  defp bind_authorization_destination(_route),
    do: {:error, {:authorization_failed, :invalid_route}}

  defp valid_authorization_route_text?(value) do
    is_binary(value) and String.valid?(value) and byte_size(value) > 0 and
      byte_size(value) <= @max_authorization_route_text_bytes and String.trim(value) == value and
      not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  # One allowlist for callback results — used by both router and legacy paths.
  defp invoke_route_authorizer(authorizer, route) when is_function(authorizer, 1) do
    case authorizer.(route) do
      :allow -> :ok
      {:requires_approval, _reason} -> {:error, {:authorization_failed, :pending}}
      _other -> {:error, {:authorization_failed, :denied}}
    end
  rescue
    _ -> {:error, {:authorization_failed, :raised}}
  catch
    _, _ -> {:error, {:authorization_failed, :raised}}
  end

  defp exact_runtime_module(runtime) do
    case Map.fetch(RuntimeRegistry.all(), runtime) do
      {:ok, module} when is_atom(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, :prepare, 2) and
             function_exported?(module, :execute, 3) do
          {:ok, module}
        else
          {:error, {:selection_failed, {:provider_route, :runtime_unavailable}}}
        end

      _ ->
        {:error, {:selection_failed, {:provider_route, :runtime_unavailable}}}
    end
  end

  defp dispatch_attempt(%{request: request, policy: policy, opts: opts}) do
    do_dispatch_once(request, policy, opts)
  end

  defp apply_dispatch_override(%{request: request, policy: policy} = attempt, override) do
    new_request = apply_request_override(request, override)
    new_policy = apply_policy_override(policy, override)

    if new_request == request and new_policy == policy do
      :no_change
    else
      {:ok, %{attempt | request: new_request, policy: new_policy}}
    end
  end

  # Run one attempt through the full select → authorize → emit → prepare → execute
  # chain. Same shape the old single-attempt `dispatch/2` had.
  defp do_dispatch_once(%Request{} = request, policy, opts) do
    extra_meta = Keyword.get(opts, :telemetry_metadata, %{})
    callbacks = Keyword.get(opts, :callbacks, %{})

    with model_entry <- ModelProfile.entry(request.model),
         {:ok, selection} <- select(model_entry, policy),
         rewritten <- rewrite_request(request, selection, model_entry),
         route <- legacy_route(model_entry, selection, rewritten),
         {:ok, bound_route} <- bind_authorization_destination(route),
         :ok <- authorize_legacy_route(Keyword.fetch(opts, :route_authorizer), bound_route) do
      :ok = emit_selected(model_entry, selection, request, extra_meta)

      runtime_module = RuntimeRegistry.lookup(selection.runtime)
      runtime_opts = runtime_opts_for(selection.runtime, opts)

      with {:ok, prepared} <- runtime_module.prepare(rewritten, runtime_opts) do
        runtime_module.execute(prepared, callbacks, runtime_opts)
      end
    end
  end

  # Source-owned route identity for legacy Selector selection. The selected
  # structs retain catalog provenance; destination/model bind the exact rewritten
  # request and prevent synthesized `:legacy` entries from collapsing providers.
  # ACP destination is finalized by bind_authorization_destination/1 to acp:<agent>.
  defp legacy_route(
         model_entry,
         %{provider: provider, runtime: runtime},
         %Request{provider: destination, model: model}
       ) do
    %{
      model_entry: model_entry,
      provider: provider,
      runtime: runtime,
      destination: destination,
      model: model
    }
  end

  # Strip private attribution from generic runtime opts; re-add only for Arbor.
  # Re-derived from the original attempt opts each primary/fallback attempt so
  # a prior non-Arbor attempt cannot leak the key into the next runtime.
  defp runtime_opts_for(runtime, opts) when is_list(opts) do
    {ctx, rest} = Keyword.pop(opts, @private_usage_opt)

    rest =
      Keyword.drop(rest, [
        :policy,
        :telemetry_metadata,
        :callbacks,
        :provider_route_input,
        :route_authorizer,
        # Internal test seam — never leak to runtime adapters.
        :route_concurrency_server
      ])

    if runtime == :arbor and is_map(ctx) and not is_struct(ctx) do
      Keyword.put(rest, @private_usage_opt, ctx)
    else
      rest
    end
  end

  @doc false
  # Errors that justify trying the next entry in the fallback chain.
  # Composes two ideas:
  #
  #   1. Transient runtime failures via `Arbor.LLM.Retry.fallback_eligible?/1`
  #      — rate-limit, timeout, 5xx, ProviderError with retryable=true.
  #      Shared with the LlmHandler tools-loop fallback wrapper so both
  #      paths classify errors identically.
  #
  #   2. Declarative path failures (`:no_cli_for_provider`,
  #      `:no_provider_supports_runtime`, pool/session crashes, selection
  #      failures). Same-path retry wouldn't help, but a *different* path
  #      legitimately could. These are Dispatch-specific (LlmHandler's
  #      tools loop goes through Client.complete, which never surfaces them).
  #
  # Non-eligible: auth errors, bad-prompt errors, and any ProviderError
  # whose `retryable` is explicitly `false` — these would fail the same
  # way on every path, so fallback would just waste budget.
  @spec fallback_eligible?(term()) :: boolean()
  def fallback_eligible?(reason) do
    Arbor.LLM.Retry.fallback_eligible?(reason) or path_unavailable_error?(reason)
  end

  defp path_unavailable_error?(reason) when is_atom(reason) do
    reason in [:pool_not_available, :pool_exhausted, :session_mod_not_available]
  end

  defp path_unavailable_error?({:no_cli_for_provider, _}), do: true
  defp path_unavailable_error?({:no_provider_supports_runtime, _}), do: true
  defp path_unavailable_error?({:no_provider_for_runtime, _}), do: true
  defp path_unavailable_error?({:requested_runtime_not_supported, _}), do: true
  defp path_unavailable_error?({:requested_provider_not_available, _}), do: true
  defp path_unavailable_error?({:pool_exit, _}), do: true
  defp path_unavailable_error?({:session_exit, _}), do: true
  defp path_unavailable_error?({:selection_failed, _}), do: true
  # At-capacity / unconfigured may try a ranked configured fallback.
  # Authority failure (:unavailable / :malformed_route) remains fail-closed.
  defp path_unavailable_error?({:route_concurrency, :at_capacity}), do: true
  defp path_unavailable_error?({:route_concurrency, :unconfigured_route}), do: true
  defp path_unavailable_error?({:route_concurrency, _}), do: false
  defp path_unavailable_error?(_), do: false

  defp apply_request_override(%Request{} = request, %{model: model})
       when is_binary(model) do
    %{request | model: model}
  end

  defp apply_request_override(%Request{} = request, _override), do: request

  defp apply_policy_override(base_policy, override) do
    base_policy
    |> maybe_put_policy(:runtime, Map.get(override, :runtime))
    |> maybe_put_policy(:provider, Map.get(override, :provider))
  end

  defp maybe_put_policy(policy, _key, nil), do: policy
  defp maybe_put_policy(policy, key, value), do: Map.put(policy, key, value)

  # FallbackLoop's on_fallback signature: (attempt, override, last_error).
  # For Dispatch, attempt is `%{request: ..., policy: ..., opts: ...}`.
  defp emit_fallback(%{request: request}, override, last_error) do
    metadata = %{
      original_model: request.model,
      override: override,
      from_error: inspect_error(last_error)
    }

    safe_telemetry([:arbor, :runtime, :fallback], %{count: 1}, metadata)
    :ok
  end

  defp emit_route_fallback(initial_attempt, route, last_error) do
    emit_fallback(initial_attempt, route_marker(route), last_error)
  end

  defp route_marker(route) do
    %{
      model: route.model_entry.canonical_id,
      provider: route.provider.id,
      runtime: route.runtime
    }
  end

  defp route_extra_meta(extra_meta) when is_map(extra_meta) do
    Map.drop(extra_meta, [
      :canonical_id,
      :provider,
      :provider_ref,
      :runtime,
      :model_family,
      "canonical_id",
      "provider",
      "provider_ref",
      "runtime",
      "model_family"
    ])
  end

  defp inspect_error({:error, reason}), do: Arbor.LLM.inspect_external_reason(reason)
  defp inspect_error(other), do: Arbor.LLM.inspect_external_reason(other)

  @doc """
  Run the selection chain without dispatching the request. Returns the
  chosen `{provider, runtime}` selection along with the resolved
  `%ModelEntry{}`. Useful for callers that want to inspect the chosen
  path without making an LLM call (cost preview, capability check,
  doctor output).

  Emits the same `[:arbor, :runtime, :selected]` telemetry event as
  `dispatch/2` so observability matches whether or not the request is
  actually sent.
  """
  @spec choose(Request.t() | String.t(), Selector.policy(), map()) ::
          {:ok, %{model_entry: ModelEntry.t(), selection: Selector.selection()}}
          | {:error, term()}
  def choose(request_or_model_id, policy \\ %{}, extra_meta \\ %{})

  def choose(%Request{} = request, policy, extra_meta) do
    with model_entry <- ModelProfile.entry(request.model),
         {:ok, selection} <- select(model_entry, policy) do
      :ok = emit_selected(model_entry, selection, request, extra_meta)
      {:ok, %{model_entry: model_entry, selection: selection}}
    end
  end

  def choose(model_id, policy, extra_meta) when is_binary(model_id) do
    model_entry = ModelProfile.entry(model_id)

    with {:ok, selection} <- select(model_entry, policy) do
      :ok = emit_selected(model_entry, selection, nil, extra_meta)
      {:ok, %{model_entry: model_entry, selection: selection}}
    end
  end

  @doc """
  Enumerate the full attempt chain (primary + each fallback override)
  without dispatching any requests.

  Walks `policy.fallback_chain` (if present) and resolves each entry's
  effective `{model_entry, selection}` against `choose/3` semantics.
  Returns a list of attempts in execution order — the primary first,
  then each fallback entry. Each result carries `:override` to indicate
  which chain entry produced it (`:primary` for the initial attempt).

  Useful for `mix arbor.doctor --model X --fallback ...` and any
  operator-facing introspection that wants to display the full path
  ladder. Does NOT emit `[:arbor, :runtime, :selected]` telemetry —
  enumeration is a preview, not a dispatch, and burning telemetry
  per row would muddy the per-turn signal.

  Failing entries are still included in the result list (as
  `{:error, reason, override}`) so callers can render rows like
  "fallback step 2: selection_failed — no_provider_supports_runtime".
  """
  @type chain_entry ::
          {:ok,
           %{
             model_entry: ModelEntry.t(),
             selection: Selector.selection(),
             override: map() | :primary,
             request: Request.t()
           }}
          | {:error, term(), map() | :primary}

  @spec enumerate_chain(Request.t() | String.t(), Selector.policy()) :: [chain_entry()]
  def enumerate_chain(request_or_model_id, policy \\ %{})

  def enumerate_chain(%Request{} = request, policy) do
    fallback_chain = Map.get(policy, :fallback_chain, [])
    base_policy = Map.delete(policy, :fallback_chain)

    primary = preview_attempt(request, base_policy, :primary)

    rest =
      Enum.map(fallback_chain, fn override ->
        attempt_request = apply_request_override(request, override)
        attempt_policy = apply_policy_override(base_policy, override)
        preview_attempt(attempt_request, attempt_policy, override)
      end)

    [primary | rest]
  end

  def enumerate_chain(model_id, policy) when is_binary(model_id) do
    enumerate_chain(%Request{model: model_id, messages: []}, policy)
  end

  defp preview_attempt(%Request{} = request, policy, marker) do
    model_entry = ModelProfile.entry(request.model)

    case select(model_entry, policy) do
      {:ok, selection} ->
        {:ok,
         %{
           model_entry: model_entry,
           selection: selection,
           override: marker,
           request: request
         }}

      {:error, reason} ->
        {:error, reason, marker}
    end
  end

  # ---- internals ----

  defp select(%ModelEntry{} = entry, policy) do
    case Selector.choose(entry, policy) do
      {:ok, selection} -> {:ok, selection}
      {:error, reason} -> {:error, {:selection_failed, reason}}
    end
  end

  # Rewrite the request's `provider` and `runtime` fields to the chosen
  # selection. Falls back to the request's original provider when the
  # selection comes from the synthesized `:legacy` provider (model
  # llm_db doesn't know about) — keep caller intent rather than overwrite
  # with "legacy". The runtime is always set from the selection.
  defp rewrite_request(
         %Request{} = request,
         %{provider: provider_entry, runtime: runtime},
         _entry
       ) do
    provider =
      case provider_entry.id do
        :legacy -> request.provider
        id -> Atom.to_string(id)
      end

    %{request | provider: provider, runtime: runtime}
  end

  defp rewrite_routed_request(%Request{} = request, route) do
    %{
      request
      | provider: Atom.to_string(route.provider.id),
        model: route.provider.ref,
        runtime: route.runtime
    }
  end

  defp emit_selected(model_entry, selection, request, extra_meta) do
    metadata =
      %{
        canonical_id: model_entry.canonical_id,
        provider: selection.provider.id,
        provider_ref: selection.provider.ref,
        runtime: selection.runtime,
        request_id: request && Map.get(request, :request_id),
        model_family: model_entry.family
      }
      |> Map.merge(extra_meta)

    safe_telemetry([:arbor, :runtime, :selected], %{count: 1}, metadata)
    :ok
  end

  defp emit_executed(route, request, attempt, provider_confirmed) do
    metadata = %{
      canonical_id: route.model_entry.canonical_id,
      provider: route.provider.id,
      provider_ref: route.provider.ref,
      runtime: route.runtime,
      request_id: bounded_request_id(request),
      attempt: attempt,
      route_identity: :router_selected,
      provider_confirmed: provider_confirmed
    }

    metadata =
      if provider_confirmed do
        Map.put(metadata, :confirmed_model, route.provider.ref)
      else
        metadata
      end

    safe_telemetry([:arbor, :runtime, :executed], %{count: 1}, metadata)
    :ok
  end

  defp put_executed_route(%Response{} = response, route, attempt, provider_confirmed) do
    usage =
      response.usage
      |> normalize_usage_map()
      |> strip_executed_route_aliases()
      |> Map.put(@executed_route_key, executed_route_evidence(route, attempt, provider_confirmed))

    %{response | usage: usage}
  end

  # A provider can report only untrusted evidence. Confirmation is admitted
  # when the typed receipt agrees exactly with the route selected by Arbor:
  # the closed backend identity and exact wire provider reference must match.
  # The canonical model remains separate route metadata. Raw payload and usage
  # aliases are intentionally ignored.
  defp provider_confirmed?(
         %Response{
           provider_receipt: %Response.ProviderReceipt{
             backend: backend,
             reported_model: reported_model
           }
         },
         route
       )
       when is_binary(reported_model) do
    backend == selected_backend(route) and reported_model == route.provider.ref
  end

  defp provider_confirmed?(_response, _route), do: false

  defp selected_backend(%{provider: %{id: :openai_oauth}}), do: :openai
  defp selected_backend(%{provider: %{id: :xai_oauth}}), do: :xai
  defp selected_backend(%{provider: %{id: backend}}) when backend in [:openai, :xai], do: backend
  defp selected_backend(_route), do: nil

  defp normalize_usage_map(usage) when is_map(usage) and not is_struct(usage), do: usage
  defp normalize_usage_map(_), do: %{}

  defp strip_executed_route_aliases(usage) when is_map(usage) and not is_struct(usage) do
    Map.drop(usage, @executed_route_aliases)
  end

  defp strip_executed_route_aliases(_usage), do: %{}

  # Closed route evidence owned by Dispatch (not the provider). Confirmed
  # evidence adds one exact model field to the legacy seven-field false form.
  defp executed_route_evidence(route, attempt, provider_confirmed) do
    evidence = %{
      "provider" => Atom.to_string(route.provider.id),
      "provider_ref" => route.provider.ref,
      "model" => route.model_entry.canonical_id,
      "runtime" => Atom.to_string(route.runtime),
      "attempt" => attempt_string(attempt),
      "route_identity" => "router_selected",
      "provider_confirmed" => provider_confirmed
    }

    if provider_confirmed do
      Map.put(evidence, "confirmed_model", route.provider.ref)
    else
      evidence
    end
  end

  defp attempt_string(:primary), do: "primary"
  defp attempt_string(:fallback), do: "fallback"
  defp attempt_string(other) when is_atom(other), do: Atom.to_string(other)
  defp attempt_string(_), do: "unknown"

  defp bounded_request_id(%Request{} = request) do
    case Map.get(request, :request_id) do
      value when is_binary(value) and byte_size(value) <= 256 -> value
      _ -> nil
    end
  end

  # :telemetry is optional dep — most umbrella runs have it, but be
  # defensive so a missing telemetry app doesn't break dispatch.
  defp safe_telemetry(event, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      apply(:telemetry, :execute, [event, measurements, metadata])
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end

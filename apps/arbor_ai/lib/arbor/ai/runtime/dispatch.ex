defmodule Arbor.AI.Runtime.Dispatch do
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

  alias Arbor.AI.Runtime.Registry, as: RuntimeRegistry
  alias Arbor.AI.Runtime.Selector
  alias Arbor.Common.ModelProfile
  alias Arbor.Contracts.LLM.ModelEntry
  alias Arbor.LLM.Client
  alias Arbor.LLM.Request
  alias Arbor.LLM.Response

  @type dispatch_opts :: [
          client: Client.t() | nil,
          policy: Selector.policy(),
          telemetry_metadata: map()
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
  @spec dispatch(Request.t(), dispatch_opts()) :: {:ok, Response.t()} | {:error, term()}
  def dispatch(%Request{} = request, opts \\ []) do
    policy = Keyword.get(opts, :policy, %{})
    fallback_chain = Map.get(policy, :fallback_chain, [])
    base_policy = Map.delete(policy, :fallback_chain)

    case do_dispatch_once(request, base_policy, opts) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error ->
        if fallback_chain != [] and fallback_eligible?(reason) do
          try_fallbacks(request, base_policy, fallback_chain, opts, error)
        else
          error
        end
    end
  end

  # Run one attempt through the full select → emit → prepare → execute
  # chain. Same shape the old single-attempt `dispatch/2` had.
  defp do_dispatch_once(%Request{} = request, policy, opts) do
    extra_meta = Keyword.get(opts, :telemetry_metadata, %{})
    callbacks = Keyword.get(opts, :callbacks, %{})

    with model_entry <- ModelProfile.entry(request.model),
         {:ok, selection} <- select(model_entry, policy) do
      :ok = emit_selected(model_entry, selection, request, extra_meta)
      rewritten = rewrite_request(request, selection, model_entry)

      runtime_module = RuntimeRegistry.lookup(selection.runtime)
      runtime_opts = Keyword.drop(opts, [:policy, :telemetry_metadata, :callbacks])

      with {:ok, prepared} <- runtime_module.prepare(rewritten, runtime_opts) do
        runtime_module.execute(prepared, callbacks, runtime_opts)
      end
    end
  end

  # Walk the fallback chain. Each entry is applied as a request/policy
  # override on top of the originals (NOT on the previous attempt) — that
  # keeps each entry's interpretation independent of which earlier entries
  # ran. Stops at the first success, or on a non-eligible error, or when
  # the chain is exhausted (returns the most recent error).
  defp try_fallbacks(_request, _base_policy, [], _opts, last_error), do: last_error

  defp try_fallbacks(request, base_policy, [override | rest], opts, last_error) do
    emit_fallback(request, last_error, override)

    attempt_request = apply_request_override(request, override)
    attempt_policy = apply_policy_override(base_policy, override)

    case do_dispatch_once(attempt_request, attempt_policy, opts) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error ->
        if rest != [] and fallback_eligible?(reason) do
          try_fallbacks(request, base_policy, rest, opts, error)
        else
          error
        end
    end
  end

  @doc false
  # Errors that justify trying the next entry in the fallback chain.
  # Composes two ideas:
  #
  #   1. Transient runtime failures (the `Arbor.LLM.Retry` classifier —
  #      rate-limit, timeout, 5xx, ProviderError with retryable=true).
  #      Inlined here rather than calling Retry because `Retry`'s
  #      `default_should_retry/1` is private. If a second caller appears,
  #      this is the prompt to extract a shared classifier.
  #
  #   2. Declarative path failures (`:no_cli_for_provider`,
  #      `:no_provider_supports_runtime`, pool/session crashes, selection
  #      failures). Same-path retry wouldn't help, but a *different* path
  #      legitimately could.
  #
  # Non-eligible: auth errors, bad-prompt errors, and any ProviderError
  # whose `retryable` is explicitly `false` — these would fail the same
  # way on every path, so fallback would just waste budget.
  @spec fallback_eligible?(term()) :: boolean()
  def fallback_eligible?(reason) do
    transient_runtime_error?(reason) or path_unavailable_error?(reason)
  end

  defp transient_runtime_error?(%Arbor.LLM.ProviderError{retryable: retryable}), do: retryable

  defp transient_runtime_error?(%mod{}) when mod == Arbor.LLM.RequestTimeoutError, do: true

  defp transient_runtime_error?(reason) when is_atom(reason) do
    reason in [:timeout, :rate_limited, :network_error, :transient_error]
  end

  defp transient_runtime_error?({:http_status, status}) when is_integer(status) do
    status == 429 or status >= 500
  end

  defp transient_runtime_error?(_), do: false

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

  defp emit_fallback(request, from_error, override) do
    metadata = %{
      original_model: request.model,
      override: override,
      from_error: inspect_error(from_error)
    }

    safe_telemetry([:arbor, :runtime, :fallback], %{count: 1}, metadata)
    :ok
  end

  defp inspect_error({:error, reason}), do: inspect(reason)
  defp inspect_error(other), do: inspect(other)

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

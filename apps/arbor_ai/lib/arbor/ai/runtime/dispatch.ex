defmodule Arbor.AI.Runtime.Dispatch do
  @moduledoc """
  High-level dispatch surface that bridges model resolution → runtime
  selection → LLM call.

  This is the seam Phase 2c will migrate the dashboard and UnifiedBridge
  onto. Today (Phase 2b) it does three things:

    1. Resolves `request.model` to a `%ModelEntry{}` via
       `Arbor.Common.ModelProfile.entry/1` (which reads llm_db).
    2. Picks `{provider, runtime}` via `Arbor.AI.Runtime.Selector.choose/2`.
    3. Emits a `[:arbor, :runtime, :selected]` telemetry event with the
       chosen tuple, then forwards to `Arbor.LLM.Client.complete/3` with
       the request's `provider` rewritten to the selected provider's id.

  The runtime atom from Selector is **observable but not yet load-bearing**
  in Phase 2b — it goes to telemetry; it doesn't drive dispatch. Today
  `Arbor.LLM.Client` already routes by the provider string (the existing
  `"acp"` adapter handles ACP-runtime traffic today via provider name).
  Phase 2c adds a `:runtime` field to `Arbor.LLM.Request`, splits the
  provider string from the runtime axis, and rewrites the ACP adapter
  so the registered `Arbor.AI.Runtime` impls (`Runtime.Arbor`,
  `Runtime.Acp`) carry their own execution distinct from provider
  selection.

  See `.arbor/roadmap/2-planned/runtime-provider-axis-split.md` for the
  Phase 2c work.

  ## Why no `Runtime.Arbor` / `Runtime.Acp` adapter modules yet

  In Phase 2b they would both delegate to `Client.complete` with minor
  argument shaping — shimmy modules that don't earn their existence.
  The behaviour from Phase 2a (`Arbor.AI.Runtime`) sits ready for
  Phase 2c when the provider/runtime axis split forces a real
  implementation divergence. See `.arbor/decisions/` for the trade-off
  capture.
  """

  require Logger

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
  Resolve a request through the runtime selection chain and forward it
  to `Arbor.LLM.Client.complete/3`.

  ## Options

    * `:client` — `%Arbor.LLM.Client{}` to dispatch through. Defaults to
      `Client.new()`, which discovers adapters from the application
      env.
    * `:policy` — `Arbor.AI.Runtime.Selector.policy()` map carrying per-
      turn override / model pins / default runtime. Defaults to `%{}`.
    * `:telemetry_metadata` — extra fields merged into the telemetry
      event metadata (request_id, agent_id, etc.). Defaults to `%{}`.

  Any other keys in `opts` pass through to `Client.complete/3`.

  ## Errors

    * Selector errors propagate as `{:error, {:selection_failed, reason}}`.
    * Client errors propagate as `{:error, reason}` from
      `Client.complete/3`.

  ## Phase 2c migration path

  When Phase 2c lands and `Arbor.LLM.Request` carries a `:runtime`
  field, this function will set it on the rewritten request and the
  registered `Runtime.<atom>` adapter takes over execution. Until then
  the runtime atom is emitted in telemetry only — useful for measuring
  who's calling for what runtime before the axis split forces commits.
  """
  @spec dispatch(Request.t(), dispatch_opts()) :: {:ok, Response.t()} | {:error, term()}
  def dispatch(%Request{} = request, opts \\ []) do
    policy = Keyword.get(opts, :policy, %{})
    extra_meta = Keyword.get(opts, :telemetry_metadata, %{})
    client = Keyword.get_lazy(opts, :client, fn -> Client.new() end)

    with model_entry <- ModelProfile.entry(request.model),
         {:ok, selection} <- select(model_entry, policy) do
      :ok = emit_selected(model_entry, selection, request, extra_meta)
      rewritten = rewrite_request(request, selection, model_entry)

      forwarded_opts = Keyword.drop(opts, [:client, :policy, :telemetry_metadata])
      Client.complete(client, rewritten, forwarded_opts)
    end
  end

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

  # Rewrite the request's `provider` string to the chosen provider's id.
  # Falls back to the request's original provider when the selection
  # comes from the synthesized `:legacy` provider (model llm_db doesn't
  # know about — keep caller intent rather than overwrite with
  # "legacy").
  defp rewrite_request(%Request{} = request, %{provider: provider_entry}, _model_entry) do
    case provider_entry.id do
      :legacy -> request
      provider_id -> %{request | provider: Atom.to_string(provider_id)}
    end
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

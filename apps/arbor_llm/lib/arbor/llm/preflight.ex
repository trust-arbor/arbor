defmodule Arbor.LLM.Preflight do
  @moduledoc """
  Preflight check that the model ids the orchestrator is configured to use are
  actually loaded on their (local) providers.

  Why this exists: local providers fail in opposite, both-bad ways when a configured
  model isn't loaded (verified 2026-05-27):

    * **LM Studio** never errors — it *silently serves a different model* (a bare or
      bogus id returns 200 with whatever happens to be loaded). So a misconfigured id
      produces wrong results with no signal — dangerous for evals especially.
    * **Ollama** 404s at call time (strict).

  This check queries each provider's *live* model list (`GET /v1/models` for LM Studio,
  `GET /api/tags` for Ollama — `Client.list_models/2` is a static catalog, not the
  loaded set) and warns when a configured id won't be served as intended. It is
  **warn-only**: it never blocks startup or a turn.

  LM Studio's `/v1/models` ids are *adaptive* to load state — one quant loaded lists the
  bare id (`gemma-4-e4b-it`), two quants list suffixed ids (`gemma-4-e4b-it@q4_k_xl`).
  Matching is therefore base-name aware (see `classify/2`).
  """

  require Logger

  alias Arbor.LLM.{Deadline, Endpoint, ResponseBudget}

  # Arbor.Orchestrator.Config lives in arbor_orchestrator (which depends
  # on arbor_llm). Runtime indirection avoids the cycle — see Client's
  # @tool_hooks_mod for the same pattern.
  @orchestrator_config_mod Arbor.Orchestrator.Config

  @http_timeout 4_000
  @max_inventory_response_bytes 1_048_576
  @max_loaded_models 10_000
  @max_model_id_bytes 512

  @type status :: :ok | {:wrong_quant, String.t()} | :unverified_quant | :missing | :unreachable
  @type entry :: %{
          stage: atom(),
          kind: :chat | :embed,
          provider: atom(),
          model: String.t(),
          base_url: String.t()
        }
  @type result :: %{entry: entry(), status: status()}

  @doc """
  Run the preflight check against the live providers and log the outcome.

  Warn-only: logs a warning for `:missing`/`:unreachable`, info for soft mismatches,
  and a single debug line when everything checks out. Never raises.
  """
  @spec check_and_log() :: :ok
  def check_and_log do
    results = check()
    log_results(results)
    :ok
  rescue
    e ->
      Logger.warning("[Preflight] model check failed (non-fatal): #{Exception.message(e)}")
      :ok
  end

  @doc """
  Check all configured model ids against their providers' loaded models.

  `fetch_fn` resolves `(provider, base_url) -> {:ok, [loaded_id]} | {:error, reason}`;
  defaults to a live HTTP query and is injectable for tests.
  """
  @spec check((atom(), String.t() -> {:ok, [String.t()]} | {:error, term()})) :: [result()]
  def check(fetch_fn \\ &loaded_models/2) do
    {results, _cache} =
      Enum.map_reduce(configured_models(), %{}, fn entry, cache ->
        key = {entry.provider, entry.base_url}

        {loaded, cache} =
          case Map.fetch(cache, key) do
            {:ok, cached} ->
              {cached, cache}

            :error ->
              fetched = fetch_fn.(entry.provider, entry.base_url)
              {fetched, Map.put(cache, key, fetched)}
          end

        status =
          case loaded do
            {:ok, ids} -> classify(entry.provider, entry.model, ids)
            {:error, _} -> :unreachable
          end

        {%{entry: entry, status: status}, cache}
      end)

    results
  end

  @doc """
  Collect every model id the orchestrator is configured to call on a *local* provider
  (`:lm_studio` / `:ollama`). Cloud providers have no "loaded model" concept and error
  cleanly on unknown ids, so they're out of scope for this check.

  Pulls from the preprocessor config (every stage, enabled or not — a disabled stage
  is still a configured id that would be used once enabled), including the retrieval
  embedding model.
  """
  @spec configured_models() :: [entry()]
  def configured_models do
    config_mod = @orchestrator_config_mod
    cfg = apply(config_mod, :preprocessor, [])

    stage_entries =
      for stage <- [:needs_tools, :complexity, :intent, :decompose, :retrieval],
          opts = cfg[stage],
          is_list(opts),
          model = opts[:model],
          is_binary(model),
          local_provider?(opts[:provider]) do
        %{
          stage: stage,
          kind: :chat,
          provider: opts[:provider],
          model: model,
          base_url: base_url_for(opts)
        }
      end

    embed_entries =
      case cfg[:retrieval] do
        opts when is_list(opts) ->
          embed = opts[:embed_model]

          if is_binary(embed) and local_provider?(opts[:provider]) do
            [
              %{
                stage: :retrieval,
                kind: :embed,
                provider: opts[:provider],
                model: embed,
                base_url: base_url_for(opts)
              }
            ]
          else
            []
          end

        _ ->
          []
      end

    Enum.uniq(stage_entries ++ embed_entries)
  end

  @doc """
  Classify a configured `model` against a provider's `loaded` ids. Provider-aware
  because the two locals name things differently.

  **Ollama** (`name:tag`, strict per-tag) — but a bare name resolves to the `:latest`
  tag, so `mxbai-embed-large` matches a loaded `mxbai-embed-large:latest`:

    * `:ok` — exact, or bare-name matches the loaded `name:latest`.
    * `:missing` — otherwise (Ollama 404s on an unknown name/tag at call time).

  **LM Studio** (`@quant` suffix; `/v1/models` adaptive to load state):

    * `:ok` — exact match; served as-is.
    * `{:wrong_quant, served}` — base loaded under a *different* quant; `served` is used.
    * `:unverified_quant` — base loaded but listed without a quant tag (one quant
      loaded → bare id); the one loaded quant is served, can't confirm it's the
      configured one.
    * `:missing` — base not loaded at all; LM Studio silently substitutes another model.
  """
  @spec classify(atom(), String.t(), [String.t()]) :: status()
  def classify(:ollama, model, loaded) do
    cond do
      model in loaded -> :ok
      not String.contains?(model, ":") and "#{model}:latest" in loaded -> :ok
      true -> :missing
    end
  end

  def classify(_lm_studio_or_other, model, loaded) do
    cond do
      model in loaded ->
        :ok

      true ->
        base = strip_quant(model)
        same_base = Enum.filter(loaded, &(strip_quant(&1) == base))

        cond do
          same_base == [] -> :missing
          base in same_base -> :unverified_quant
          true -> {:wrong_quant, hd(same_base)}
        end
    end
  end

  @doc "Strip an LM Studio `@quant` suffix (`gemma-4-e4b-it@q4_k_xl` -> `gemma-4-e4b-it`). No-op for Ollama `name:tag` ids."
  @spec strip_quant(String.t()) :: String.t()
  def strip_quant(model), do: model |> String.split("@", parts: 2) |> hd()

  @doc """
  Query a local provider's *loaded* models. Returns `{:ok, [id]}` or `{:error, reason}`.
  """
  @spec loaded_models(atom(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def loaded_models(provider, base_url) when provider in [:lm_studio, :ollama] do
    with {:ok, receipt} <- Deadline.receipt(timeout_ms: @http_timeout) do
      Deadline.run(
        fn ->
          with {:ok, url} <- Endpoint.model_inventory(provider, base_url),
               {:ok, body} <- get_inventory(url, receipt),
               {:ok, ids} <- extract_inventory_ids(provider, body) do
            {:ok, ids}
          end
        end,
        receipt,
        {:inventory_deadline_exceeded, @http_timeout}
      )
    end
  end

  def loaded_models(other, _base_url), do: {:error, {:unsupported_provider, other}}

  # ── helpers ──────────────────────────────────────────────────────────

  defp get_inventory(url, receipt) do
    request =
      Req.new(
        url: url,
        method: :get,
        receive_timeout: max(receipt.deadline_ms - System.monotonic_time(:millisecond), 1),
        retry: false
      )
      |> ResponseBudget.apply_req_receipt(@max_inventory_response_bytes)

    case Req.request(request) do
      {:ok,
       %Req.Response{
         private: %{arbor_response_overflow: @max_inventory_response_bytes}
       }} ->
        {:error, {:response_bytes_exceeded, @max_inventory_response_bytes}}

      {:ok, %Req.Response{private: %{arbor_response_error: reason}}} ->
        {:error, {:invalid_inventory_response, reason}}

      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, {:inventory_request_failed, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:inventory_request_failed, kind}}
  end

  defp extract_inventory_ids(:lm_studio, %{"data" => entries}),
    do: collect_inventory_ids(entries, "id", [], 0)

  defp extract_inventory_ids(:ollama, %{"models" => entries}),
    do: collect_inventory_ids(entries, "name", [], 0)

  defp extract_inventory_ids(_provider, _body),
    do: {:error, :invalid_inventory_response}

  defp collect_inventory_ids([], _key, acc, _count), do: {:ok, Enum.reverse(acc)}

  defp collect_inventory_ids(_entries, _key, _acc, count)
       when count >= @max_loaded_models,
       do: {:error, {:loaded_model_count_exceeded, @max_loaded_models}}

  defp collect_inventory_ids([entry | rest], key, acc, count) when is_map(entry) do
    case Map.get(entry, key) do
      id
      when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_model_id_bytes ->
        if String.valid?(id),
          do: collect_inventory_ids(rest, key, [id | acc], count + 1),
          else: {:error, :invalid_loaded_model_id}

      _invalid ->
        {:error, :invalid_loaded_model_id}
    end
  end

  defp collect_inventory_ids(_improper_or_invalid, _key, _acc, _count),
    do: {:error, :invalid_inventory_response}

  defp local_provider?(p), do: p in [:lm_studio, :ollama]

  defp base_url_for(opts) do
    case opts[:base_url] do
      url when is_binary(url) -> url
      _ -> default_base_url(opts[:provider])
    end
  end

  defp default_base_url(:lm_studio), do: "http://localhost:1234/v1"

  # Ollama's loaded-model probe hits the native /api/tags endpoint (see
  # loaded_models/2), so this default must be the BARE base URL (no /v1).
  # Honour ARBOR_OLLAMA_BASE_URL so CI / homelab deployments point the
  # preflight check at the same Ollama the call path uses.
  defp default_base_url(:ollama) do
    (System.get_env("ARBOR_OLLAMA_BASE_URL") || "http://localhost:11434")
    |> String.replace_suffix("/v1", "")
  end

  defp default_base_url(_), do: ""

  defp log_results(results) do
    Enum.each(results, fn %{entry: e, status: status} ->
      tag = "#{e.stage}/#{e.kind} #{e.provider} #{e.model}"

      case status do
        :ok ->
          :ok

        :missing ->
          Logger.warning(
            "[Preflight] #{tag}: NOT LOADED on #{e.base_url}. " <>
              if(e.provider == :lm_studio,
                do: "LM Studio will SILENTLY serve a different model.",
                else: "Provider will 404 at call time."
              )
          )

        {:wrong_quant, served} ->
          Logger.info(
            "[Preflight] #{tag}: configured quant not loaded; provider will serve '#{served}' instead."
          )

        :unverified_quant ->
          Logger.info(
            "[Preflight] #{tag}: base model loaded but listed without a quant tag; " <>
              "the one loaded quant will be served (can't confirm it matches the configured quant)."
          )

        :unreachable ->
          Logger.warning(
            "[Preflight] #{tag}: could not reach #{e.base_url} to verify the model is loaded."
          )
      end
    end)

    ok_count = Enum.count(results, &(&1.status == :ok))

    Logger.debug(
      "[Preflight] #{ok_count}/#{length(results)} configured local models verified loaded"
    )
  end
end

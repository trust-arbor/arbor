defmodule Arbor.LLM.OpenCodeZen do
  @moduledoc """
  Keyless OpenCode Zen free-tier LLM provider.

  Endpoint `https://opencode.ai/zen/v1` is OpenAI-compatible. Auth is
  anonymous: a credential must NOT reach the wire. The relay 401s any
  unknown bearer, including placeholders and paid OpenCode Go keys.

  ## Data disclosure

  Before Arbor sends any request to OpenCode's API (https://opencode.ai/zen):

    1. Your prompts, and any context the agent includes — such as file
       contents and command output — are sent to OpenCode's API.
    2. Arbor makes NO representations or guarantees about OpenCode's
       data-handling or privacy claims, whatever their documentation states.
    3. Do not use this free tier for sensitive, confidential, or regulated data.

  You must actively acknowledge this once. Arbor stores that acknowledgement
  locally and will not re-prompt on later runs.

  ## Credential shape

  This is a distinct `:anonymous` credential shape — not an empty string
  through the API-key path. Missing or blank keys for every other
  provider still fail closed.

  ## Admission

  The model list is derived from recorded eval evidence in
  `priv/opencode_zen/admission.json`. Dispatch refuses any id that is
  not on that admitted list. Re-run
  `mix arbor.eval.opencode_zen --live` to refresh it from a two-tier
  probe. A model that cannot emit tool calls never reaches a
  proposal and is rejected.
  """

  alias Arbor.LLM.OpenCodeZen.{AdmissionCore, Disclosure, Transport}

  @provider "opencode_zen"
  @provider_atom :opencode_zen
  @base_url "https://opencode.ai/zen/v1"
  @admission_cache_key {__MODULE__, :admission}
  @admission_load_count_key {__MODULE__, :admission_loads}

  @spec provider() :: String.t()
  def provider, do: @provider

  @spec provider_atom() :: atom()
  def provider_atom, do: @provider_atom

  @spec base_url() :: String.t()
  def base_url, do: @base_url

  @spec provider?(atom() | String.t()) :: boolean()
  def provider?(value) when value in [@provider, @provider_atom], do: true

  def provider?(value) when is_atom(value) or is_binary(value) do
    Arbor.LLM.ProviderRegistry.normalize(value) == @provider
  end

  def provider?(_), do: false

  @spec disclosure_text() :: String.t()
  def disclosure_text, do: Disclosure.text()

  @spec ensure_acknowledged() :: :ok | {:error, :disclosure_not_acknowledged}
  def ensure_acknowledged, do: Disclosure.ensure()

  @spec prompt_acknowledgement(keyword()) :: :ok | {:error, :disclosure_not_acknowledged}
  def prompt_acknowledgement(opts \\ []), do: Disclosure.prompt(opts)

  @spec acknowledged?() :: boolean()
  def acknowledged?, do: Disclosure.acknowledged?()

  @spec catalog() :: AdmissionCore.t()
  def catalog do
    case load_admission() do
      {:ok, payload} -> AdmissionCore.new(payload)
      {:error, _} -> AdmissionCore.new(%{})
    end
  end

  @spec admitted_ids() :: [String.t()]
  def admitted_ids, do: catalog() |> AdmissionCore.admitted_ids()

  @spec admitted() :: [map()]
  def admitted, do: catalog() |> AdmissionCore.admitted()

  @spec rejected() :: [map()]
  def rejected, do: catalog() |> AdmissionCore.rejected()

  @spec listing() :: String.t()
  def listing, do: catalog() |> AdmissionCore.show()

  @doc """
  Permit dispatch only for a model present in the admitted catalog.

  Unknown, rejected, and blank ids fail closed with
  `{:opencode_zen_model_not_admitted, id}`. An unreadable catalog fails
  closed with `:opencode_zen_admission_unreadable`.
  """
  @spec admit_model(term()) ::
          :ok
          | {:error, :opencode_zen_admission_unreadable}
          | {:error, {:opencode_zen_model_not_admitted, term()}}
  def admit_model(id) do
    cond do
      not is_binary(id) or id == "" ->
        {:error, {:opencode_zen_model_not_admitted, id}}

      probe_model?(id) ->
        :ok

      true ->
        case load_admission() do
          {:error, reason} ->
            {:error, reason}

          {:ok, payload} ->
            if AdmissionCore.admitted_id?(AdmissionCore.new(payload), id) do
              :ok
            else
              {:error, {:opencode_zen_model_not_admitted, id}}
            end
        end
    end
  end

  @spec list_models() :: [map()]
  def list_models do
    Enum.map(admitted(), fn record ->
      %{
        id: Map.get(record, "id"),
        name: Map.get(record, "id"),
        provider: @provider,
        limits: %{context: Map.get(record, "context_window")},
        disclosure: disclosure_text()
      }
    end)
  end

  @spec transport_headers() :: [{String.t(), String.t()}]
  def transport_headers, do: Transport.attribution_headers()

  @spec apply_anonymous_auth(term()) :: term()
  def apply_anonymous_auth(request), do: Transport.apply_anonymous_auth(request)

  @doc "Write a new admission payload and invalidate the cached entry for that path."
  @spec persist_admission(map()) :: :ok | {:error, :opencode_zen_admission_unreadable}
  def persist_admission(payload) when is_map(payload) do
    path = admission_path()
    :ok = File.mkdir_p(Path.dirname(path))

    case File.write(path, JSON.encode!(payload) <> "\n") do
      :ok ->
        invalidate_admission_cache(path)
        :ok

      {:error, _reason} ->
        {:error, :opencode_zen_admission_unreadable}
    end
  end

  @doc false
  @spec reset_admission_cache() :: :ok
  def reset_admission_cache do
    _ = :persistent_term.erase(@admission_cache_key)
    _ = :persistent_term.erase(@admission_load_count_key)
    :ok
  end

  @doc false
  @spec admission_load_count(String.t() | nil) :: non_neg_integer()
  def admission_load_count(path \\ nil) do
    key = path || admission_path()
    :persistent_term.get(@admission_load_count_key, %{}) |> Map.get(key, 0)
  end

  @doc false
  @spec with_probe_models([String.t()], (-> result)) :: result when result: var
  def with_probe_models(ids, fun) when is_list(ids) and is_function(fun, 0) do
    previous = Application.get_env(:arbor_llm, :opencode_zen_probe_ids)
    Application.put_env(:arbor_llm, :opencode_zen_probe_ids, ids)

    try do
      fun.()
    after
      restore_env(:opencode_zen_probe_ids, previous)
    end
  end

  defp load_admission do
    path = admission_path()
    cache = :persistent_term.get(@admission_cache_key, %{})

    case Map.fetch(cache, path) do
      {:ok, result} ->
        result

      :error ->
        result = read_admission()
        :persistent_term.put(@admission_cache_key, Map.put(cache, path, result))
        bump_load_count(path)
        result
    end
  end

  defp read_admission do
    case File.read(admission_path()) do
      {:ok, contents} ->
        case JSON.decode(contents) do
          {:ok, payload} when is_map(payload) -> {:ok, payload}
          _ -> {:error, :opencode_zen_admission_unreadable}
        end

      _ ->
        {:error, :opencode_zen_admission_unreadable}
    end
  end

  defp admission_path do
    case Application.get_env(:arbor_llm, :opencode_zen_admission_path) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        Application.app_dir(:arbor_llm, "priv/opencode_zen/admission.json")
    end
  end

  defp bump_load_count(path) do
    counts = :persistent_term.get(@admission_load_count_key, %{})
    :persistent_term.put(@admission_load_count_key, Map.update(counts, path, 1, &(&1 + 1)))
  end

  defp invalidate_admission_cache(path) do
    cache = :persistent_term.get(@admission_cache_key, %{})
    :persistent_term.put(@admission_cache_key, Map.delete(cache, path))
    counts = :persistent_term.get(@admission_load_count_key, %{})
    :persistent_term.put(@admission_load_count_key, Map.delete(counts, path))
    :ok
  end

  defp probe_model?(id) do
    case Application.get_env(:arbor_llm, :opencode_zen_probe_ids, []) do
      ids when is_list(ids) -> id in ids
      _ -> false
    end
  end

  defp restore_env(_key, nil), do: Application.delete_env(:arbor_llm, :opencode_zen_probe_ids)
  defp restore_env(key, value), do: Application.put_env(:arbor_llm, key, value)
end

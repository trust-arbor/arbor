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
  @probe_ids_key {__MODULE__, :probe_ids}
  @probe_opt :opencode_zen_probe_ids
  @eval_probes_table :arbor_llm_opencode_zen_eval_probes
  @max_eval_probe_ids 32
  @max_probe_id_bytes 512

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
  @spec admit_model(term(), keyword()) ::
          :ok
          | {:error, :opencode_zen_admission_unreadable}
          | {:error, {:opencode_zen_model_not_admitted, term()}}
  def admit_model(id, opts \\ []) when is_list(opts) do
    cond do
      not is_binary(id) or id == "" ->
        {:error, {:opencode_zen_model_not_admitted, id}}

      probe_authorized?(id, opts) ->
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

  @doc """
  Free-tier candidate ids discovered from the relay's own catalog.

  Deliberately NOT sourced from the local admission file: that file is this
  probe's output, so reading it would make discovery circular and unable to
  find a model it does not already list.
  """
  @spec discover_free_candidates(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def discover_free_candidates(opts \\ []), do: Transport.discover_free_candidates(opts)

  @spec apply_anonymous_auth(term()) :: term()
  def apply_anonymous_auth(request), do: Transport.apply_anonymous_auth(request)

  @doc "Write a new admission payload. The next admit/list call re-reads the file."
  @spec persist_admission(map()) :: :ok | {:error, :opencode_zen_admission_unreadable}
  def persist_admission(payload) when is_map(payload) do
    path = admission_path()
    :ok = File.mkdir_p(Path.dirname(path))

    case File.write(path, JSON.encode!(payload) <> "\n") do
      :ok ->
        :ok

      {:error, _reason} ->
        {:error, :opencode_zen_admission_unreadable}
    end
  end

  @doc false
  # Probe authorization is minted on the evaluator process and copied onto
  # evaluator-owned dispatch opts before Deadline.run/3. Caller-supplied
  # probe ids on public complete/stream/embed opts are stripped.
  @spec with_probe_models([String.t()], (-> result)) :: result when result: var
  def with_probe_models(ids, fun) when is_list(ids) and is_function(fun, 0) do
    previous = Process.get(@probe_ids_key)
    Process.put(@probe_ids_key, ids)

    try do
      fun.()
    after
      restore_probe_ids(previous)
    end
  end

  @doc false
  @spec carry_probe_authorization(term()) :: term()
  def carry_probe_authorization(opts) when is_list(opts) do
    opts = Keyword.delete(opts, @probe_opt)

    case Process.get(@probe_ids_key) do
      ids when is_list(ids) -> Keyword.put(opts, @probe_opt, ids)
      _ -> opts
    end
  end

  def carry_probe_authorization(opts), do: opts

  @doc false
  # Eval-scoped probe pin keyed by the execution principal. Heartbeat/Engine
  # workers do not inherit Mix-task process dictionary, so `with_probe_models/2`
  # never reaches `admit_model/2` on that path. Do not use Application env:
  # that pin is VM-global and would admit the model for every other agent in
  # the same BEAM (including Bootstrap/Reconciler auto-starts).
  @spec register_eval_probes(String.t(), [String.t()]) ::
          :ok | {:error, :invalid_eval_probe_registration}
  def register_eval_probes(agent_id, ids)
      when is_binary(agent_id) and is_list(ids) do
    if valid_eval_principal?(agent_id) do
      case sanitize_probe_ids(ids) do
        [] ->
          unregister_eval_probes(agent_id)

        cleaned ->
          table = ensure_eval_probes_table()
          true = :ets.insert(table, {agent_id, cleaned})
          :ok
      end
    else
      {:error, :invalid_eval_probe_registration}
    end
  end

  def register_eval_probes(_agent_id, _ids), do: {:error, :invalid_eval_probe_registration}

  @doc false
  @spec unregister_eval_probes(term()) :: :ok
  def unregister_eval_probes(agent_id) when is_binary(agent_id) do
    case :ets.whereis(@eval_probes_table) do
      :undefined ->
        :ok

      tid ->
        :ets.delete(tid, agent_id)
        :ok
    end
  end

  def unregister_eval_probes(_agent_id), do: :ok

  @doc false
  @spec ensure_eval_probes_table() :: :ets.table()
  def ensure_eval_probes_table do
    case :ets.whereis(@eval_probes_table) do
      :undefined ->
        try do
          :ets.new(@eval_probes_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError ->
            case :ets.whereis(@eval_probes_table) do
              :undefined ->
                raise "OpenCode Zen eval probe table missing after create race"

              tid ->
                tid
            end
        end

      tid ->
        tid
    end
  end

  defp load_admission do
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

  defp probe_authorized?(id, opts) do
    id in keyword_probe_ids(opts) or id in process_probe_ids() or
      id in eval_probe_ids(eval_probe_principal(opts))
  end

  defp keyword_probe_ids(opts) do
    case Keyword.get(opts, @probe_opt) do
      ids when is_list(ids) -> ids
      _ -> []
    end
  end

  defp process_probe_ids do
    case Process.get(@probe_ids_key, []) do
      ids when is_list(ids) -> ids
      _ -> []
    end
  end

  defp eval_probe_principal(opts) when is_list(opts) do
    case Keyword.get(opts, :agent_id) do
      agent_id when is_binary(agent_id) ->
        if valid_eval_principal?(agent_id), do: agent_id, else: nil

      _ ->
        nil
    end
  end

  defp eval_probe_principal(_opts), do: nil

  defp eval_probe_ids(agent_id) when is_binary(agent_id) do
    case :ets.whereis(@eval_probes_table) do
      :undefined ->
        []

      tid ->
        case :ets.lookup(tid, agent_id) do
          [{^agent_id, ids}] when is_list(ids) -> Enum.filter(ids, &is_binary/1)
          _ -> []
        end
    end
  end

  defp eval_probe_ids(_agent_id), do: []

  defp valid_eval_principal?(agent_id) when is_binary(agent_id) do
    byte_size(agent_id) > byte_size("agent_") and byte_size(agent_id) <= 256 and
      String.valid?(agent_id) and String.starts_with?(agent_id, "agent_") and
      String.trim(agent_id) == agent_id and not String.match?(agent_id, ~r/[\x00-\x1F\x7F]/)
  end

  defp valid_eval_principal?(_), do: false

  defp sanitize_probe_ids(ids) when is_list(ids) do
    ids
    |> Enum.filter(&valid_probe_id?/1)
    |> Enum.take(@max_eval_probe_ids)
    |> Enum.uniq()
  end

  defp valid_probe_id?(id) when is_binary(id) do
    id != "" and byte_size(id) <= @max_probe_id_bytes and String.valid?(id) and
      not String.contains?(id, <<0>>)
  end

  defp valid_probe_id?(_), do: false

  defp restore_probe_ids(nil), do: Process.delete(@probe_ids_key)
  defp restore_probe_ids(ids), do: Process.put(@probe_ids_key, ids)
end

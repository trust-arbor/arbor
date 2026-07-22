defmodule Arbor.Contracts.Coding.TaskOutcome do
  @moduledoc """
  Versioned, closed JSON contract for the outcome of a coding task.

  The contract records an outcome as data only. It contains no authority,
  executable callback, capability, identity, or instruction to retry work.
  Atom and string keys are accepted at the input boundary, while `to_map/1`
  always returns canonical string keys and string enum values.
  """

  use TypedStruct

  @schema_version 1

  @dispositions ~w(succeeded requires_input rejected failed cancelled)
  @phases ~w(
    preflight
    workspace
    worker_start
    worker_turn
    validation
    review
    commit
    adoption
    cleanup
    control
  )
  @origins ~w(arbor security acp_transport provider worker validator reviewer operator runtime)
  @retries ~w(none same_session new_session after_external_change)

  # These values are the closed status vocabularies currently emitted by the
  # ACP action/session paths. `provider_account_exhausted` is an action-level
  # delivery receipt; the other delivery values are task-control terminal
  # states. Completion deliberately does not use ACP transcript `success`:
  # only an explicit `end_turn` stop reason is a trusted worker completion.
  @delivery_states ~w(delivered not_delivered delivery_unknown cancelled provider_account_exhausted)
  @completion_states ~w(
    end_turn
    provider_error
    timeout
    inactivity_timeout
    stream_callback_failure
    stream_callback_timeout
    prompt_exit
    client_down
    cancelled
  )

  @fields [
    :version,
    :disposition,
    :code,
    :phase,
    :origin,
    :retry,
    :message,
    :diagnostic_refs,
    :evidence_ref,
    :delivery_state,
    :completion_state,
    :worker_session_id,
    :provider_session_id,
    :provider,
    :requested_model,
    :confirmed_model
  ]
  @required_fields [:version, :disposition, :code, :phase, :origin, :retry]
  @max_fields length(@fields)
  @max_code_bytes 128
  @max_text_bytes 4_096
  @max_ref_bytes 512
  @max_diagnostic_refs 32

  typedstruct enforce: true do
    @typedoc "A bounded, authority-free coding task outcome."

    field(:version, pos_integer())
    field(:disposition, String.t())
    field(:code, String.t())
    field(:phase, String.t())
    field(:origin, String.t())
    field(:retry, String.t())
    field(:message, String.t() | nil, default: nil)
    field(:diagnostic_refs, [String.t()], default: [])
    field(:evidence_ref, String.t() | nil, default: nil)
    field(:delivery_state, String.t() | nil, default: nil)
    field(:completion_state, String.t() | nil, default: nil)
    field(:worker_session_id, String.t() | nil, default: nil)
    field(:provider_session_id, String.t() | nil, default: nil)
    field(:provider, String.t() | nil, default: nil)
    field(:requested_model, String.t() | nil, default: nil)
    field(:confirmed_model, String.t() | nil, default: nil)
  end

  @doc "Return the accepted schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Return the accepted disposition values."
  @spec dispositions() :: [String.t()]
  def dispositions, do: @dispositions

  @doc "Return the accepted phase values."
  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc "Return the accepted origin values."
  @spec origins() :: [String.t()]
  def origins, do: @origins

  @doc "Return the accepted retry values."
  @spec retries() :: [String.t()]
  def retries, do: @retries

  @doc "Return the closed ACP delivery-state values."
  @spec delivery_states() :: [String.t()]
  def delivery_states, do: @delivery_states

  @doc "Return the closed completion states, including trusted `end_turn`."
  @spec completion_states() :: [String.t()]
  def completion_states, do: @completion_states

  @doc "Construct and validate a closed task outcome object."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_object(attrs),
         :ok <- require_fields(attrs),
         {:ok, version} <- normalize_version(attrs.version),
         {:ok, disposition} <- normalize_enum(attrs.disposition, :disposition, @dispositions),
         {:ok, code} <- normalize_string(attrs.code, :code, @max_code_bytes),
         {:ok, phase} <- normalize_enum(attrs.phase, :phase, @phases),
         {:ok, origin} <- normalize_enum(attrs.origin, :origin, @origins),
         {:ok, retry} <- normalize_enum(attrs.retry, :retry, @retries),
         {:ok, message} <- optional_string(attrs, :message, @max_text_bytes),
         {:ok, diagnostic_refs} <- normalize_diagnostic_refs(attrs),
         {:ok, evidence_ref} <- optional_string(attrs, :evidence_ref, @max_ref_bytes),
         {:ok, delivery_state} <- optional_enum(attrs, :delivery_state, @delivery_states),
         {:ok, completion_state} <- optional_enum(attrs, :completion_state, @completion_states),
         {:ok, worker_session_id} <- optional_string(attrs, :worker_session_id, @max_ref_bytes),
         {:ok, provider_session_id} <-
           optional_string(attrs, :provider_session_id, @max_ref_bytes),
         {:ok, provider} <- optional_string(attrs, :provider, @max_ref_bytes),
         {:ok, requested_model} <- optional_string(attrs, :requested_model, @max_ref_bytes),
         {:ok, confirmed_model} <- optional_string(attrs, :confirmed_model, @max_ref_bytes) do
      {:ok,
       %__MODULE__{
         version: version,
         disposition: disposition,
         code: code,
         phase: phase,
         origin: origin,
         retry: retry,
         message: message,
         diagnostic_refs: diagnostic_refs,
         evidence_ref: evidence_ref,
         delivery_state: delivery_state,
         completion_state: completion_state,
         worker_session_id: worker_session_id,
         provider_session_id: provider_session_id,
         provider: provider,
         requested_model: requested_model,
         confirmed_model: confirmed_model
       }}
    end
  rescue
    _ -> {:error, {:invalid_task_outcome, :malformed}}
  catch
    _, _ -> {:error, {:invalid_task_outcome, :malformed}}
  end

  @doc "Return the deterministic canonical string-keyed JSON representation."
  @spec to_map(t()) :: %{required(String.t()) => term()}
  def to_map(%__MODULE__{} = outcome) do
    %{
      "version" => outcome.version,
      "disposition" => outcome.disposition,
      "code" => outcome.code,
      "phase" => outcome.phase,
      "origin" => outcome.origin,
      "retry" => outcome.retry
    }
    |> maybe_put("message", outcome.message)
    |> maybe_put_nonempty("diagnostic_refs", outcome.diagnostic_refs)
    |> maybe_put("evidence_ref", outcome.evidence_ref)
    |> maybe_put("delivery_state", outcome.delivery_state)
    |> maybe_put("completion_state", outcome.completion_state)
    |> maybe_put("worker_session_id", outcome.worker_session_id)
    |> maybe_put("provider_session_id", outcome.provider_session_id)
    |> maybe_put("provider", outcome.provider)
    |> maybe_put("requested_model", outcome.requested_model)
    |> maybe_put("confirmed_model", outcome.confirmed_model)
  end

  defp normalize_object(attrs) when is_map(attrs) do
    cond do
      is_struct(attrs) -> {:error, {:invalid_object, "task_outcome"}}
      map_size(attrs) > @max_fields -> {:error, {:invalid_object, "task_outcome"}}
      true -> normalize_entries(Map.to_list(attrs))
    end
  end

  defp normalize_object(attrs) when is_list(attrs) do
    cond do
      not proper_list?(attrs) -> {:error, {:invalid_object, "task_outcome"}}
      length(attrs) > @max_fields -> {:error, {:invalid_object, "task_outcome"}}
      not Enum.all?(attrs, &match?({_, _}, &1)) -> {:error, {:invalid_object, "task_outcome"}}
      true -> normalize_entries(attrs)
    end
  end

  defp normalize_object(_attrs), do: {:error, {:invalid_object, "task_outcome"}}

  defp normalize_entries(entries) do
    named_entries =
      Enum.map(entries, fn {key, value} ->
        case key_name(key) do
          {:ok, name} -> {name, value}
          :error -> {nil, value}
        end
      end)

    invalid_keys =
      named_entries
      |> Enum.filter(&is_nil(elem(&1, 0)))
      |> Enum.map(fn {_key, _value} -> "<invalid>" end)

    unknown_fields =
      named_entries
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 in Enum.map(@fields, fn field -> Atom.to_string(field) end)))
      |> Enum.uniq()
      |> Enum.sort()

    duplicate_fields =
      named_entries
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_field, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    cond do
      invalid_keys != [] ->
        {:error, {:invalid_object_key, "task_outcome"}}

      duplicate_fields != [] ->
        {:error, {:duplicate_fields, duplicate_fields}}

      unknown_fields != [] ->
        {:error, {:unknown_fields, unknown_fields}}

      true ->
        fields_by_name = Map.new(@fields, &{Atom.to_string(&1), &1})

        {:ok,
         Map.new(named_entries, fn {name, value} ->
           {Map.fetch!(fields_by_name, name), value}
         end)}
    end
  end

  defp key_name(key) when is_atom(key), do: {:ok, Atom.to_string(key)}

  defp key_name(key) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: :error
  end

  defp key_name(_key), do: :error

  defp require_fields(attrs) do
    case Enum.find(@required_fields, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> {:error, {:missing_field, Atom.to_string(field)}}
    end
  end

  defp normalize_version(@schema_version), do: {:ok, @schema_version}
  defp normalize_version(_value), do: {:error, {:invalid_field, "version"}}

  defp normalize_enum(value, field, allowed) when is_atom(value),
    do: normalize_enum(Atom.to_string(value), field, allowed)

  defp normalize_enum(value, field, allowed) when is_binary(value) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  defp normalize_enum(_value, field, _allowed),
    do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp optional_enum(attrs, field, allowed) do
    case Map.fetch(attrs, field) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> normalize_enum(value, field, allowed)
    end
  end

  defp normalize_string(value, field, maximum) when is_binary(value) do
    if valid_text?(value, maximum),
      do: {:ok, value},
      else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  defp normalize_string(_value, field, _maximum),
    do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp optional_string(attrs, field, maximum) do
    case Map.fetch(attrs, field) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> normalize_string(value, field, maximum)
    end
  end

  defp normalize_diagnostic_refs(attrs) do
    case Map.fetch(attrs, :diagnostic_refs) do
      :error ->
        {:ok, []}

      {:ok, nil} ->
        {:ok, []}

      {:ok, refs} when is_list(refs) and length(refs) <= @max_diagnostic_refs ->
        refs
        |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
          case normalize_string(ref, :diagnostic_ref, @max_ref_bytes) do
            {:ok, ref} -> {:cont, {:ok, [ref | acc]}}
            {:error, _} -> {:halt, {:error, {:invalid_field, "diagnostic_refs"}}}
          end
        end)
        |> case do
          {:ok, refs} -> {:ok, Enum.reverse(refs)}
          {:error, _} = error -> error
        end

      {:ok, _refs} ->
        {:error, {:invalid_field, "diagnostic_refs"}}
    end
  end

  defp valid_text?(value, maximum) do
    String.valid?(value) and String.trim(value) != "" and byte_size(value) <= maximum and
      not String.contains?(value, <<0>>) and not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_nonempty(map, _key, []), do: map
  defp maybe_put_nonempty(map, key, value), do: Map.put(map, key, value)
end

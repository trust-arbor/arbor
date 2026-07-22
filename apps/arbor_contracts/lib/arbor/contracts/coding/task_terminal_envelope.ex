defmodule Arbor.Contracts.Coding.TaskTerminalEnvelope do
  @moduledoc """
  Closed, bounded JSON contract published for every opted-in coding terminal.

  Outcomes are either preserved from exact registered evidence or constructed
  from an exact registry code. Evidence is data only: executable terms,
  capabilities, authority-bearing fields, and raw runtime errors are rejected.
  """

  use TypedStruct

  alias Arbor.Contracts.Coding.TaskOutcome

  @schema_version 1
  @terminal_states ~w(done failed cancelled)
  @fields [:version, :terminal_state, :outcome, :prior_outcome, :evidence]
  @evidence_fields ~w(kind result approval_id truncated)
  @evidence_kinds ~w(
    executor_result
    pipeline_failure
    task_cancelled
    task_owner_died
    approval_owner_terminated
    task_runner_failed
    invalid_terminal_evidence
  )
  @forbidden_evidence_keys MapSet.new(~w(
    authority
    authorizer
    callback
    callbacks
    capabilities
    capability
    function
    functions
    identity_private_key
    module
    modules
    pid
    port
    private_key
    reference
    signing_key
  ))
  @max_depth 6
  @max_nodes 96
  @max_string_bytes 512
  @max_key_bytes 256
  @max_encoded_bytes 65_536

  typedstruct enforce: true do
    @typedoc "A canonical JSON terminal envelope before `to_map/1` projection."

    field(:version, pos_integer())
    field(:terminal_state, String.t())
    field(:outcome, map())
    field(:prior_outcome, map() | nil, default: nil)
    field(:evidence, map())
  end

  @doc "Return the accepted envelope schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Construct an envelope from an exact registered code."
  @spec from_code(String.t(), String.t() | atom(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def from_code(code, terminal_state, evidence, optional_outcome_attrs \\ %{}) do
    with {:ok, outcome} <- TaskOutcome.from_code(code, optional_outcome_attrs) do
      build(terminal_state, TaskOutcome.to_map(outcome), nil, evidence)
    end
  end

  @doc "Preserve an existing canonical outcome after validating registry semantics."
  @spec preserve(map(), String.t() | atom(), map()) :: {:ok, map()} | {:error, term()}
  def preserve(outcome, terminal_state, evidence) do
    with {:ok, outcome} <- TaskOutcome.validate_registered(outcome) do
      build(terminal_state, TaskOutcome.to_map(outcome), nil, evidence)
    end
  end

  @doc "Wrap finalizer failure without discarding the prior outcome or evidence."
  @spec finalization_failed(map()) :: {:ok, map()} | {:error, term()}
  def finalization_failed(envelope) do
    with {:ok, prior} <- normalize(envelope),
         {:ok, outcome} <- TaskOutcome.from_code("task_finalization_failed") do
      build("failed", TaskOutcome.to_map(outcome), prior["outcome"], prior["evidence"])
    end
  end

  @doc "Normalize and validate a terminal envelope to its canonical JSON map."
  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def normalize(attrs) do
    with {:ok, attrs} <- normalize_object(attrs),
         :ok <- require_fields(attrs),
         :ok <- validate_version(attrs.version),
         {:ok, terminal_state} <- normalize_terminal_state(attrs.terminal_state),
         {:ok, outcome} <- normalize_outcome(attrs.outcome),
         {:ok, prior_outcome} <- normalize_optional_outcome(Map.get(attrs, :prior_outcome)),
         {:ok, evidence} <- normalize_evidence(attrs.evidence) do
      envelope = %__MODULE__{
        version: @schema_version,
        terminal_state: terminal_state,
        outcome: outcome,
        prior_outcome: prior_outcome,
        evidence: evidence
      }

      {:ok, to_map(envelope)}
    end
  rescue
    _ -> {:error, {:invalid_terminal_envelope, :malformed}}
  catch
    _, _ -> {:error, {:invalid_terminal_envelope, :malformed}}
  end

  @doc "Return the canonical string-keyed JSON representation."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = envelope) do
    %{
      "version" => envelope.version,
      "terminal_state" => envelope.terminal_state,
      "outcome" => envelope.outcome,
      "evidence" => envelope.evidence
    }
    |> maybe_put("prior_outcome", envelope.prior_outcome)
  end

  defp build(terminal_state, outcome, prior_outcome, evidence) do
    normalize(%{
      version: @schema_version,
      terminal_state: terminal_state,
      outcome: outcome,
      prior_outcome: prior_outcome,
      evidence: evidence
    })
  end

  defp normalize_object(attrs) when is_map(attrs) and not is_struct(attrs),
    do: normalize_entries(Map.to_list(attrs))

  defp normalize_object(attrs) when is_list(attrs) do
    if proper_list?(attrs) and Enum.all?(attrs, &match?({_, _}, &1)),
      do: normalize_entries(attrs),
      else: {:error, {:invalid_terminal_envelope, :object_required}}
  end

  defp normalize_object(_attrs), do: {:error, {:invalid_terminal_envelope, :object_required}}

  defp normalize_entries(entries) when length(entries) <= length(@fields) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, field} <- normalize_field(key),
           false <- Map.has_key?(acc, field) do
        {:cont, {:ok, Map.put(acc, field, value)}}
      else
        true -> {:halt, {:error, {:duplicate_field, printable_key(key)}}}
        :error -> {:halt, {:error, {:unknown_field, printable_key(key)}}}
      end
    end)
  end

  defp normalize_entries(_entries), do: {:error, {:invalid_terminal_envelope, :object_too_large}}

  defp normalize_field(key) when is_atom(key),
    do: if(key in @fields, do: {:ok, key}, else: :error)

  defp normalize_field(key) when is_binary(key) do
    Enum.find_value(@fields, :error, fn field ->
      if Atom.to_string(field) == key, do: {:ok, field}
    end)
  end

  defp normalize_field(_key), do: :error

  defp require_fields(attrs) do
    case Enum.find([:version, :terminal_state, :outcome, :evidence], &(!Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> {:error, {:missing_field, Atom.to_string(field)}}
    end
  end

  defp validate_version(@schema_version), do: :ok
  defp validate_version(_version), do: {:error, {:invalid_field, "version"}}

  defp normalize_terminal_state(state) when is_atom(state),
    do: normalize_terminal_state(Atom.to_string(state))

  defp normalize_terminal_state(state) when state in @terminal_states, do: {:ok, state}
  defp normalize_terminal_state(_state), do: {:error, {:invalid_field, "terminal_state"}}

  defp normalize_outcome(outcome) do
    with {:ok, typed} <- TaskOutcome.validate_registered(outcome) do
      {:ok, TaskOutcome.to_map(typed)}
    end
  end

  defp normalize_optional_outcome(nil), do: {:ok, nil}
  defp normalize_optional_outcome(outcome), do: normalize_outcome(outcome)

  defp normalize_evidence(evidence) when is_map(evidence) and not is_struct(evidence) do
    with true <- Enum.all?(Map.keys(evidence), &is_binary/1),
         [] <- Map.keys(evidence) -- @evidence_fields,
         kind when kind in @evidence_kinds <- Map.get(evidence, "kind"),
         :ok <- validate_evidence_shape(kind, evidence),
         {:ok, bounded_result, truncated} <- normalize_optional_result(evidence) do
      normalized =
        %{"kind" => kind}
        |> maybe_put("result", bounded_result)
        |> maybe_put("approval_id", normalize_approval_id(evidence["approval_id"]))
        |> maybe_put_true("truncated", truncated or evidence["truncated"] == true)

      with {:ok, encoded} <- Jason.encode(normalized),
           true <- byte_size(encoded) <= @max_encoded_bytes do
        {:ok, normalized}
      else
        _ -> {:error, {:invalid_field, "evidence"}}
      end
    else
      _ -> {:error, {:invalid_field, "evidence"}}
    end
  end

  defp normalize_evidence(_evidence), do: {:error, {:invalid_field, "evidence"}}

  defp validate_evidence_shape("approval_owner_terminated", evidence) do
    if valid_approval_id?(evidence["approval_id"]), do: :ok, else: {:error, :invalid_approval_id}
  end

  defp validate_evidence_shape(kind, evidence)
       when kind in ["executor_result", "pipeline_failure"] do
    if Map.has_key?(evidence, "result"), do: :ok, else: {:error, :missing_result}
  end

  defp validate_evidence_shape(_kind, _evidence), do: :ok

  defp normalize_optional_result(%{"result" => result}) do
    with {:ok, clean, _nodes_left, truncated} <- bound_json(result, 0, @max_nodes) do
      {:ok, clean, truncated}
    end
  end

  defp normalize_optional_result(_evidence), do: {:ok, nil, false}

  defp bound_json(_value, _depth, nodes_left) when nodes_left <= 0,
    do: {:ok, nil, 0, true}

  defp bound_json(value, _depth, nodes_left) when is_boolean(value) or is_nil(value),
    do: {:ok, value, nodes_left - 1, false}

  defp bound_json(value, _depth, nodes_left) when is_integer(value),
    do: {:ok, value, nodes_left - 1, false}

  defp bound_json(value, _depth, nodes_left) when is_float(value) do
    case Jason.encode(value) do
      {:ok, _encoded} -> {:ok, value, nodes_left - 1, false}
      {:error, _reason} -> {:error, :non_json_number}
    end
  end

  defp bound_json(value, _depth, nodes_left) when is_binary(value) do
    if String.valid?(value) do
      {bounded, truncated} = truncate_utf8(value, @max_string_bytes)
      {:ok, bounded, nodes_left - 1, truncated}
    else
      {:error, :invalid_string}
    end
  end

  defp bound_json(value, depth, nodes_left) when is_list(value) do
    cond do
      not proper_list?(value) ->
        {:error, :improper_list}

      depth >= @max_depth ->
        {:ok, [], nodes_left - 1, value != []}

      true ->
        Enum.reduce_while(value, {:ok, [], nodes_left - 1, false}, fn item,
                                                                      {:ok, acc, left, truncated} ->
          if left <= 0 do
            {:halt, {:ok, acc, 0, true}}
          else
            case bound_json(item, depth + 1, left) do
              {:ok, clean, remaining, item_truncated} ->
                {:cont, {:ok, [clean | acc], remaining, truncated or item_truncated}}

              {:error, _reason} = error ->
                {:halt, error}
            end
          end
        end)
        |> reverse_bounded_list()
    end
  end

  defp bound_json(value, depth, nodes_left) when is_map(value) and not is_struct(value) do
    cond do
      not Enum.all?(Map.keys(value), &valid_json_key?/1) ->
        {:error, :invalid_map_key}

      Enum.any?(Map.keys(value), &MapSet.member?(@forbidden_evidence_keys, &1)) ->
        {:error, :forbidden_evidence_key}

      depth >= @max_depth ->
        {:ok, %{}, nodes_left - 1, map_size(value) > 0}

      true ->
        value
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce_while({:ok, %{}, nodes_left - 1, false}, fn {key, item},
                                                                   {:ok, acc, left, truncated} ->
          if left <= 0 do
            {:halt, {:ok, acc, 0, true}}
          else
            case bound_json(item, depth + 1, left) do
              {:ok, clean, remaining, item_truncated} ->
                {:cont, {:ok, Map.put(acc, key, clean), remaining, truncated or item_truncated}}

              {:error, _reason} = error ->
                {:halt, error}
            end
          end
        end)
    end
  end

  defp bound_json(_value, _depth, _nodes_left), do: {:error, :non_json_value}

  defp reverse_bounded_list({:ok, acc, nodes_left, truncated}),
    do: {:ok, Enum.reverse(acc), nodes_left, truncated}

  defp reverse_bounded_list({:error, _reason} = error), do: error

  defp valid_json_key?(key) when is_binary(key) do
    String.valid?(key) and byte_size(key) <= @max_key_bytes
  end

  defp valid_json_key?(_key), do: false

  defp truncate_utf8(value, maximum) when byte_size(value) <= maximum, do: {value, false}

  defp truncate_utf8(value, maximum) do
    value
    |> binary_part(0, maximum)
    |> trim_invalid_suffix()
    |> then(&{&1, true})
  end

  defp trim_invalid_suffix(value) do
    cond do
      String.valid?(value) -> value
      byte_size(value) == 0 -> ""
      true -> value |> binary_part(0, byte_size(value) - 1) |> trim_invalid_suffix()
    end
  end

  defp normalize_approval_id(value) when is_binary(value) do
    if valid_approval_id?(value), do: value
  end

  defp normalize_approval_id(_value), do: nil

  defp valid_approval_id?(value) when is_binary(value) do
    String.valid?(value) and String.trim(value) != "" and byte_size(value) <= @max_key_bytes and
      not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  defp valid_approval_id?(_value), do: false

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp printable_key(key) when is_atom(key), do: Atom.to_string(key)
  defp printable_key(key) when is_binary(key), do: key
  defp printable_key(_key), do: "<non-string-key>"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_true(map, _key, false), do: map
  defp maybe_put_true(map, key, true), do: Map.put(map, key, true)
end

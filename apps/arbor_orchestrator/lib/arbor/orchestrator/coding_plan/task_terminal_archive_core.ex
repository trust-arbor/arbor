defmodule Arbor.Orchestrator.CodingPlan.TaskTerminalArchiveCore do
  @moduledoc """
  Pure construction and validation for the immutable all-terminal task archive.

  The terminal evidence kind records how TaskStore observed completion; the
  terminal state records TaskStore's outer lifecycle state; and the outcome is
  preserved from the exact registered evidence. Consequently, an
  `executor_result` has state `done` and a `pipeline_failure` has state `failed`,
  but either may preserve any non-cancelled registered non-lifecycle outcome.
  In particular, pipeline failures may legitimately preserve dispositions such
  as `requires_input` or `rejected` without changing the outer failed state.

  Dedicated lifecycle evidence has an exact state/code pairing. A legacy
  finalizer failure is the sole form with `prior_outcome`: it has failed state,
  the `task_finalization_failed` outcome, and preserves executor or invalid
  terminal evidence from the original callback.

  This module performs no filesystem, configuration, clock, or process effects.
  Its canonical bytes and descriptor fields are deterministic functions of the
  exact TaskStore callback values.
  """

  alias Arbor.Contracts.Coding.TaskTerminalEnvelope

  @schema_version 1
  @max_task_id_bytes 512
  @max_controls 100
  @max_control_bytes 16_384
  @max_archive_bytes 1_048_576
  @max_archive_depth 9
  @max_archive_nodes 2_048

  @control_keys Enum.sort(~w(
    control_id
    task_id
    sequence
    status
    sender_id
    message
    queued_at
    delivered_at
    target_stage
    delivery_mode
    error
  ))

  @terminal_control_states ~w(delivered delivery_unconfirmed unsupported)
  @delivery_modes ~w(native_tool_loop acp_native same_session_follow_up next_stage)

  @lifecycle_terminals %{
    "task_cancelled" => {"cancelled", "task_cancelled"},
    "task_owner_died" => {"failed", "task_owner_died"},
    "approval_owner_terminated" => {"failed", "approval_owner_terminated"},
    "task_runner_failed" => {"failed", "task_runner_failed"},
    "invalid_terminal_evidence" => {"failed", "invalid_terminal_evidence"}
  }

  @reserved_lifecycle_codes MapSet.new([
                              "task_cancelled",
                              "task_owner_died",
                              "approval_owner_terminated",
                              "task_runner_failed",
                              "invalid_terminal_evidence",
                              "task_finalization_failed"
                            ])

  @type archive :: %{
          required(:body) => map(),
          required(:encoded) => binary(),
          required(:descriptor_fields) => map()
        }

  @doc "Build the exact deterministic archive from one TaskStore terminal callback."
  @spec build(term(), term(), term()) :: {:ok, archive()} | {:error, term()}
  def build(task_id, terminal_envelope, controls) do
    with :ok <- validate_task_id(task_id),
         {:ok, terminal_envelope} <- validate_exact_envelope(terminal_envelope),
         :ok <- validate_terminal_semantics(terminal_envelope),
         :ok <- validate_embedded_task_ids(terminal_envelope, task_id),
         {:ok, controls} <- validate_controls(controls, task_id, true),
         body = archive_body(task_id, terminal_envelope, controls),
         :ok <- validate_archive_bounds(body),
         {:ok, encoded} <- encode_canonical(body),
         :ok <- validate_archive_size(encoded) do
      {:ok,
       %{
         body: body,
         encoded: encoded,
         descriptor_fields: descriptor_fields(task_id, terminal_envelope, encoded)
       }}
    end
  rescue
    _exception -> {:error, :invalid_task_terminal_archive}
  catch
    _kind, _reason -> {:error, :invalid_task_terminal_archive}
  end

  @doc false
  @spec validate_control_history(term(), term()) :: {:ok, list()} | {:error, term()}
  def validate_control_history(task_id, controls) do
    with :ok <- validate_task_id(task_id) do
      validate_controls(controls, task_id, false)
    end
  rescue
    _exception -> {:error, {:invalid_terminal_controls, :expected_list}}
  catch
    _kind, _reason -> {:error, {:invalid_terminal_controls, :expected_list}}
  end

  defp validate_task_id(task_id)
       when is_binary(task_id) and byte_size(task_id) <= @max_task_id_bytes do
    if String.valid?(task_id) and String.trim(task_id) != "" and
         not String.match?(task_id, ~r/[\x00-\x1F\x7F]/) do
      :ok
    else
      {:error, {:invalid_terminal_task_id, :invalid_value}}
    end
  end

  defp validate_task_id(_task_id),
    do: {:error, {:invalid_terminal_task_id, :invalid_value}}

  defp validate_exact_envelope(envelope)
       when is_map(envelope) and not is_struct(envelope) do
    with true <- Enum.all?(Map.keys(envelope), &is_binary/1),
         {:ok, normalized} <- TaskTerminalEnvelope.normalize(envelope),
         true <- normalized === envelope do
      {:ok, envelope}
    else
      _ -> {:error, :invalid_task_terminal_envelope}
    end
  end

  defp validate_exact_envelope(_envelope),
    do: {:error, :invalid_task_terminal_envelope}

  defp validate_terminal_semantics(envelope) do
    state = envelope["terminal_state"]
    outcome = envelope["outcome"]
    code = outcome["code"]
    disposition = outcome["disposition"]
    kind = envelope["evidence"]["kind"]
    prior? = Map.has_key?(envelope, "prior_outcome")

    valid? =
      finalization_failure?(state, code, disposition, prior?, kind) or
        preserved_runner_terminal?(state, code, disposition, prior?, kind) or
        lifecycle_terminal?(state, code, disposition, prior?, kind)

    if valid?, do: :ok, else: {:error, :invalid_task_terminal_semantics}
  end

  defp finalization_failure?(state, code, disposition, prior?, kind) do
    state == "failed" and code == "task_finalization_failed" and disposition == "failed" and
      prior? and kind in ["executor_result", "invalid_terminal_evidence"]
  end

  defp preserved_runner_terminal?(state, code, disposition, prior?, kind) do
    expected_state = %{"executor_result" => "done", "pipeline_failure" => "failed"}

    Map.get(expected_state, kind) == state and not prior? and disposition != "cancelled" and
      not MapSet.member?(@reserved_lifecycle_codes, code)
  end

  defp lifecycle_terminal?(state, code, disposition, prior?, kind) do
    case Map.fetch(@lifecycle_terminals, kind) do
      {:ok, {expected_state, expected_code}} ->
        state == expected_state and code == expected_code and disposition == expected_state and
          not prior?

      :error ->
        false
    end
  end

  defp validate_embedded_task_ids(value, task_id) do
    case collect_embedded_task_ids(value, []) do
      {:ok, ids} ->
        if Enum.all?(ids, &(&1 == task_id)),
          do: :ok,
          else: {:error, :task_terminal_task_id_mismatch}

      :error ->
        {:error, :task_terminal_task_id_mismatch}
    end
  end

  defp collect_embedded_task_ids(map, acc) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, acc}, fn
      {"task_id", value}, {:ok, ids} when is_binary(value) ->
        {:cont, {:ok, [value | ids]}}

      {"task_id", _value}, _acc ->
        {:halt, :error}

      {_key, value}, {:ok, ids} ->
        case collect_embedded_task_ids(value, ids) do
          {:ok, nested_ids} -> {:cont, {:ok, nested_ids}}
          :error -> {:halt, :error}
        end
    end)
  end

  defp collect_embedded_task_ids(list, acc) when is_list(list) do
    if proper_list?(list) do
      Enum.reduce_while(list, {:ok, acc}, fn value, {:ok, ids} ->
        case collect_embedded_task_ids(value, ids) do
          {:ok, nested_ids} -> {:cont, {:ok, nested_ids}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp collect_embedded_task_ids(_value, acc), do: {:ok, acc}

  defp validate_controls(controls, task_id, require_terminal?) when is_list(controls) do
    cond do
      not proper_list?(controls) ->
        {:error, {:invalid_terminal_controls, :expected_list}}

      length(controls) > @max_controls ->
        {:error, {:invalid_terminal_controls, :too_many}}

      true ->
        controls
        |> Enum.reduce_while({:ok, {[], MapSet.new(), MapSet.new(), 0}}, fn control,
                                                                            {:ok,
                                                                             {acc, ids, sequences,
                                                                              previous}} ->
          case validate_control(
                 control,
                 task_id,
                 ids,
                 sequences,
                 previous,
                 require_terminal?
               ) do
            {:ok, control_id, sequence} ->
              {:cont,
               {:ok,
                {[control | acc], MapSet.put(ids, control_id), MapSet.put(sequences, sequence),
                 sequence}}}

            {:error, _reason} = error ->
              {:halt, error}
          end
        end)
        |> case do
          {:ok, {validated, _ids, _sequences, _previous}} -> {:ok, Enum.reverse(validated)}
          {:error, _reason} = error -> error
        end
    end
  end

  defp validate_controls(_controls, _task_id, _require_terminal?),
    do: {:error, {:invalid_terminal_controls, :expected_list}}

  defp validate_control(control, task_id, ids, sequences, previous, require_terminal?)
       when is_map(control) and not is_struct(control) do
    with true <- Enum.sort(Map.keys(control)) == @control_keys,
         :ok <- validate_json_value(control),
         {:ok, encoded} <- Jason.encode(control),
         true <- byte_size(encoded) <= @max_control_bytes,
         control_id when is_binary(control_id) <- control["control_id"],
         true <- valid_bounded_string?(control_id, 256),
         false <- MapSet.member?(ids, control_id),
         ^task_id <- control["task_id"],
         sequence when is_integer(sequence) and sequence > previous <- control["sequence"],
         false <- MapSet.member?(sequences, sequence) do
      case require_terminal? and validate_control_terminal_values(control) do
        false -> {:ok, control_id, sequence}
        :ok -> {:ok, control_id, sequence}
        {:error, _reason} = error -> error
      end
    else
      _ ->
        {:error, {:invalid_terminal_control, :identity_or_order}}
    end
  rescue
    _exception -> {:error, {:invalid_terminal_control, :malformed}}
  catch
    _kind, _reason -> {:error, {:invalid_terminal_control, :malformed}}
  end

  defp validate_control(
         _control,
         _task_id,
         _ids,
         _sequences,
         _previous,
         _require_terminal?
       ),
       do: {:error, {:invalid_terminal_control, :expected_map}}

  defp validate_control_terminal_values(control) do
    with status when status in @terminal_control_states <- control["status"],
         :ok <- validate_control_strings(control),
         :ok <- validate_control_state(control, status) do
      :ok
    else
      _ -> {:error, {:invalid_terminal_control, :nonterminal_or_malformed}}
    end
  end

  defp validate_control_strings(control) do
    with :ok <- validate_optional_string(control["sender_id"], 512),
         :ok <- validate_required_string(control["message"], 4_000),
         :ok <- validate_required_string(control["queued_at"], 128),
         :ok <- validate_optional_string(control["delivered_at"], 128),
         :ok <- validate_optional_string(control["target_stage"], 200),
         :ok <- validate_optional_string(control["delivery_mode"], 128),
         :ok <- validate_optional_string(control["error"], 512) do
      :ok
    else
      _ -> {:error, {:invalid_terminal_control, :nonterminal_or_malformed}}
    end
  end

  defp validate_optional_string(nil, _maximum), do: :ok
  defp validate_optional_string(value, maximum), do: validate_required_string(value, maximum)

  defp validate_required_string(value, maximum) do
    if valid_bounded_string?(value, maximum),
      do: :ok,
      else: {:error, :invalid_control_string}
  end

  defp valid_bounded_string?(value, maximum) do
    is_binary(value) and byte_size(value) <= maximum and String.valid?(value) and
      String.trim(value) != ""
  end

  defp validate_control_state(control, "delivered") do
    if is_binary(control["delivered_at"]) and control["delivery_mode"] in @delivery_modes and
         is_nil(control["error"]),
       do: :ok,
       else: {:error, :invalid_delivered_control}
  end

  defp validate_control_state(control, "delivery_unconfirmed") do
    if is_nil(control["delivered_at"]) and is_binary(control["error"]) and
         (is_nil(control["delivery_mode"]) or control["delivery_mode"] in @delivery_modes),
       do: :ok,
       else: {:error, :invalid_unconfirmed_control}
  end

  defp validate_control_state(control, "unsupported") do
    if is_nil(control["delivered_at"]) and is_nil(control["delivery_mode"]) and
         is_binary(control["error"]),
       do: :ok,
       else: {:error, :invalid_unsupported_control}
  end

  defp archive_body(task_id, terminal_envelope, controls) do
    %{
      "schema_version" => @schema_version,
      "task_id" => task_id,
      "terminal_envelope" => terminal_envelope,
      "controls" => controls
    }
  end

  defp descriptor_fields(task_id, terminal_envelope, encoded) do
    %{
      "schema_version" => @schema_version,
      "task_id" => task_id,
      "sha256" => sha256(encoded),
      "byte_size" => byte_size(encoded),
      "terminal_state" => terminal_envelope["terminal_state"],
      "outcome_code" => terminal_envelope["outcome"]["code"]
    }
  end

  defp validate_archive_bounds(body) do
    case consume_json(body, 0, @max_archive_nodes) do
      {:ok, _nodes_left} -> :ok
      :error -> {:error, :task_terminal_bounds_exceeded}
    end
  end

  defp consume_json(_value, _depth, nodes_left) when nodes_left <= 0, do: :error
  defp consume_json(_value, depth, _nodes_left) when depth > @max_archive_depth, do: :error

  defp consume_json(value, _depth, nodes_left)
       when is_boolean(value) or is_nil(value) or is_integer(value),
       do: {:ok, nodes_left - 1}

  defp consume_json(value, _depth, nodes_left) when is_float(value) do
    case Jason.encode(value) do
      {:ok, _encoded} -> {:ok, nodes_left - 1}
      _ -> :error
    end
  end

  defp consume_json(value, _depth, nodes_left) when is_binary(value) do
    if String.valid?(value), do: {:ok, nodes_left - 1}, else: :error
  end

  defp consume_json(value, depth, nodes_left) when is_list(value) do
    if proper_list?(value) do
      Enum.reduce_while(value, {:ok, nodes_left - 1}, fn item, {:ok, left} ->
        case consume_json(item, depth + 1, left) do
          {:ok, next_left} -> {:cont, {:ok, next_left}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp consume_json(value, depth, nodes_left)
       when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, nodes_left - 1}, fn
      {key, item}, {:ok, left} when is_binary(key) ->
        if String.valid?(key) do
          case consume_json(item, depth + 1, left - 1) do
            {:ok, next_left} -> {:cont, {:ok, next_left}}
            :error -> {:halt, :error}
          end
        else
          {:halt, :error}
        end

      {_key, _item}, _acc ->
        {:halt, :error}
    end)
  end

  defp consume_json(_value, _depth, _nodes_left), do: :error

  defp validate_json_value(value) do
    case consume_json(value, 0, @max_archive_nodes) do
      {:ok, _nodes_left} -> :ok
      :error -> {:error, :invalid_json}
    end
  end

  defp encode_canonical(value) do
    value
    |> canonicalize_json()
    |> Jason.encode(pretty: true)
    |> case do
      {:ok, encoded} -> {:ok, encoded}
      _error -> {:error, :invalid_task_terminal_archive}
    end
  end

  defp canonicalize_json(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonicalize_json(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize_json(list) when is_list(list), do: Enum.map(list, &canonicalize_json/1)
  defp canonicalize_json(value), do: value

  defp validate_archive_size(encoded) when byte_size(encoded) <= @max_archive_bytes, do: :ok
  defp validate_archive_size(_encoded), do: {:error, :task_terminal_too_large}

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_value), do: false
end

defmodule Arbor.Actions.Coding.DesignCouncilCore do
  @moduledoc """
  Pure decision logic for the advisory design-council gate.

  Turns seat evaluations into `checkpoint_outcome` (`"approve"` | `"rework"`),
  a bounded consolidated `note`, and `dispersion` counts. Errors and abstains
  never count as approvals. The question builder uses explicit per-section
  byte budgets and never tail-clips; overflow fails closed.
  """

  alias Arbor.Contracts.Coding.DesignArtifactDescriptor

  @default_veto_perspectives ["adversarial", "security", "stability"]
  @default_reject_threshold 3
  @default_min_responders 7
  @max_note_entries 24
  @max_note_entry_bytes 400
  @max_question_bytes 65_536
  @max_task_bytes 4_096
  @max_list_section_bytes 4_096
  @max_list_items 32

  @question_preamble """
  Advisory design review. Each seat must answer approve or rework.
  Rework answers must name concrete missing requirements. This council cannot deny the task.
  """

  @section_labels %{
    "task" => "Task:",
    "success_criteria" => "Success criteria:",
    "constraints" => "Constraints:",
    "non_goals" => "Non-goals:",
    "architecture_refs" => "Architecture refs:",
    "design" => "Design:"
  }

  @approve_votes MapSet.new([:approve, "approve"])
  @reject_votes MapSet.new([:reject, "reject", :rework, "rework"])
  @abstain_votes MapSet.new([:abstain, "abstain"])

  @doc "Construct a normalized rule + evaluation state from input."
  @spec new(map()) :: {:ok, map()} | {:error, term()}
  def new(params) when is_map(params) do
    with {:ok, evaluations} <- normalize_evaluations(value(params, :evaluations)),
         {:ok, rule} <- normalize_rule(params) do
      {:ok, %{"evaluations" => evaluations, "rule" => rule}}
    end
  end

  def new(_params), do: {:error, :invalid_design_council_input}

  @doc "Reduce evaluations into an outcome, note, and dispersion counts."
  @spec decide(map()) :: {:ok, map()} | {:error, term()}
  def decide(%{"evaluations" => evaluations, "rule" => rule}) do
    classified = Enum.map(evaluations, &classify/1)
    dispersion = count_dispersion(classified)
    outcome = outcome(classified, rule, dispersion)
    note = consolidate_note(classified, outcome)

    {:ok,
     %{
       "checkpoint_outcome" => outcome,
       "note" => note,
       "dispersion" => dispersion
     }}
  end

  def decide(_state), do: {:error, :invalid_design_council_state}

  @doc "Convert a decided state to the action-facing result map."
  @spec show(map()) :: {:ok, map()} | {:error, :invalid_design_council_state}
  def show(%{"checkpoint_outcome" => _, "note" => _, "dispersion" => _} = result),
    do: {:ok, result}

  def show(_result), do: {:error, :invalid_design_council_state}

  @doc """
  Build the bounded advisory question from the admitted packet fields and design.

  The worker-supplied design text is never read here; the caller must pass the
  artifact-loaded design. Each required section has an explicit byte budget.
  The assembled prompt is never tail-clipped.
  """
  @spec build_question(map(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def build_question(packet, task, design)
      when is_map(packet) and is_binary(task) and is_binary(design) do
    with {:ok, task} <- required_section(task, "task", @max_task_bytes),
         {:ok, design} <- required_section(design, "design", DesignArtifactDescriptor.max_bytes()),
         {:ok, success} <-
           required_list_section(list_field(packet, "success_criteria"), "success_criteria"),
         {:ok, constraints} <-
           required_list_section(list_field(packet, "constraints"), "constraints"),
         {:ok, non_goals} <- required_list_section(list_field(packet, "non_goals"), "non_goals"),
         {:ok, refs} <-
           required_list_section(list_field(packet, "architecture_refs"), "architecture_refs") do
      question =
        [
          String.trim_trailing(@question_preamble),
          "",
          @section_labels["task"],
          task,
          "",
          @section_labels["success_criteria"],
          success,
          "",
          @section_labels["constraints"],
          constraints,
          "",
          @section_labels["non_goals"],
          non_goals,
          "",
          @section_labels["architecture_refs"],
          refs,
          "",
          @section_labels["design"],
          design
        ]
        |> Enum.join("\n")

      if byte_size(question) <= @max_question_bytes do
        {:ok, question}
      else
        {:error, :design_council_question_overflow}
      end
    end
  end

  def build_question(_packet, _task, _design), do: {:error, :invalid_design_council_question}

  defp normalize_rule(params) do
    with {:ok, veto} <- normalize_veto_perspectives(value(params, :veto_perspectives)),
         {:ok, reject_threshold} <-
           normalize_positive_int(value(params, :reject_threshold), @default_reject_threshold),
         {:ok, min_responders} <-
           normalize_positive_int(value(params, :min_responders), @default_min_responders) do
      {:ok,
       %{
         "veto_perspectives" => veto,
         "reject_threshold" => reject_threshold,
         "min_responders" => min_responders
       }}
    end
  end

  defp normalize_veto_perspectives(nil), do: {:ok, @default_veto_perspectives}

  defp normalize_veto_perspectives(values) when is_list(values) do
    names =
      values
      |> Enum.map(&perspective_name/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    if names == [], do: {:error, :invalid_veto_perspectives}, else: {:ok, names}
  end

  defp normalize_veto_perspectives(_values), do: {:error, :invalid_veto_perspectives}

  defp normalize_positive_int(nil, default), do: {:ok, default}

  defp normalize_positive_int(value, _default)
       when is_integer(value) and value > 0 and value <= 1_000,
       do: {:ok, value}

  defp normalize_positive_int(_value, _default), do: {:error, :invalid_design_council_rule}

  defp normalize_evaluations(evaluations) when is_list(evaluations) do
    {:ok, Enum.map(evaluations, &normalize_evaluation/1)}
  end

  defp normalize_evaluations(_evaluations), do: {:error, :invalid_design_council_evaluations}

  defp normalize_evaluation({perspective, {:error, reason}}) do
    %{
      "perspective" => perspective_name(perspective),
      "vote" => "error",
      "concerns" => [],
      "reason" => inspect_reason(reason)
    }
  end

  defp normalize_evaluation({perspective, evaluation}) when is_map(evaluation) do
    case concerns_of(evaluation) do
      {:ok, concerns} ->
        %{
          "perspective" => perspective_name(perspective) || perspective_from(evaluation),
          "vote" => vote_of(evaluation),
          "concerns" => concerns,
          "reason" => nil
        }

      :error ->
        malformed_evaluation(perspective_name(perspective) || perspective_from(evaluation))
    end
  end

  defp normalize_evaluation(evaluation) when is_map(evaluation) do
    case concerns_of(evaluation) do
      {:ok, concerns} ->
        %{
          "perspective" => perspective_from(evaluation),
          "vote" => vote_of(evaluation),
          "concerns" => concerns,
          "reason" => nil
        }

      :error ->
        malformed_evaluation(perspective_from(evaluation))
    end
  end

  defp normalize_evaluation(_other) do
    malformed_evaluation(nil)
  end

  defp malformed_evaluation(perspective) do
    %{
      "perspective" => perspective,
      "vote" => "error",
      "concerns" => [],
      "reason" => "malformed"
    }
  end

  defp classify(evaluation) do
    vote = evaluation["vote"]

    kind =
      cond do
        vote in @approve_votes or vote == "approve" -> "approve"
        vote in @reject_votes or vote == "reject" or vote == "rework" -> "reject"
        vote in @abstain_votes or vote == "abstain" -> "abstain"
        true -> "error"
      end

    Map.put(evaluation, "kind", kind)
  end

  defp count_dispersion(classified) do
    counts = Enum.frequencies_by(classified, & &1["kind"])

    approve = Map.get(counts, "approve", 0)
    reject = Map.get(counts, "reject", 0)
    abstain = Map.get(counts, "abstain", 0)
    error = Map.get(counts, "error", 0)

    %{
      "approve" => approve,
      "reject" => reject,
      "abstain" => abstain,
      "error" => error,
      "responded" => approve + reject
    }
  end

  defp outcome(classified, rule, dispersion) do
    veto? =
      Enum.any?(classified, fn evaluation ->
        evaluation["kind"] == "reject" and
          evaluation["perspective"] in rule["veto_perspectives"]
      end)

    cond do
      veto? -> "rework"
      dispersion["reject"] >= rule["reject_threshold"] -> "rework"
      dispersion["responded"] < rule["min_responders"] -> "rework"
      true -> "approve"
    end
  end

  defp consolidate_note(_classified, "approve"), do: ""

  defp consolidate_note(classified, "rework") do
    classified
    |> Enum.filter(&(&1["kind"] == "reject"))
    |> Enum.flat_map(&concern_lines/1)
    |> Enum.map(&normalize_note_line/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_note_entries)
    |> Enum.map_join("\n", &clip_note_line/1)
  end

  defp concern_lines(evaluation) do
    case evaluation["concerns"] do
      [_ | _] = concerns ->
        concerns

      _ ->
        case evaluation["reason"] do
          reason when is_binary(reason) and reason != "" -> [reason]
          _ -> []
        end
    end
  end

  defp normalize_note_line(value) when is_binary(value), do: String.trim(value)
  defp normalize_note_line(_value), do: ""

  defp clip_note_line(value) when byte_size(value) <= @max_note_entry_bytes, do: value

  defp clip_note_line(value) do
    value
    |> binary_part(0, @max_note_entry_bytes)
    |> trim_incomplete_utf8()
  end

  defp trim_incomplete_utf8(""), do: ""

  defp trim_incomplete_utf8(prefix) do
    if String.valid?(prefix) do
      prefix
    else
      trim_incomplete_utf8(binary_part(prefix, 0, byte_size(prefix) - 1))
    end
  end

  defp vote_of(evaluation) when is_map(evaluation) do
    Map.get(evaluation, :vote) || Map.get(evaluation, "vote") || "abstain"
  end

  defp concerns_of(evaluation) when is_map(evaluation) do
    cond do
      Map.has_key?(evaluation, :concerns) ->
        normalize_concern_list(Map.get(evaluation, :concerns))

      Map.has_key?(evaluation, "concerns") ->
        normalize_concern_list(Map.get(evaluation, "concerns"))

      is_binary(evaluation[:reasoning]) ->
        normalize_concern_list([evaluation[:reasoning]])

      is_binary(evaluation["reasoning"]) ->
        normalize_concern_list([evaluation["reasoning"]])

      true ->
        {:ok, []}
    end
  end

  defp normalize_concern_list(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_concern_term(item) do
        {:ok, ""} -> {:cont, {:ok, acc}}
        {:ok, text} -> {:cont, {:ok, [text | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp normalize_concern_list(_values), do: :error

  defp normalize_concern_term(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, String.trim(value)}, else: :error
  end

  defp normalize_concern_term(_value), do: :error

  defp perspective_from(evaluation) when is_map(evaluation) do
    perspective_name(Map.get(evaluation, :perspective) || Map.get(evaluation, "perspective"))
  end

  defp perspective_name(nil), do: nil
  defp perspective_name(value) when is_atom(value), do: Atom.to_string(value)
  defp perspective_name(value) when is_binary(value), do: if(String.valid?(value), do: value)
  defp perspective_name(_value), do: nil

  defp inspect_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp inspect_reason(reason) when is_binary(reason) do
    if String.valid?(reason), do: reason, else: "error"
  end

  defp inspect_reason(_reason), do: "error"

  defp list_field(packet, key) when is_binary(key) do
    Map.get(packet, key) || []
  end

  defp required_section(value, field, maximum) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        {:error, {:invalid_design_council_text, field}}

      byte_size(value) > maximum ->
        {:error, {:design_council_section_overflow, field}}

      true ->
        {:ok, value}
    end
  end

  defp required_section(_value, field, _maximum),
    do: {:error, {:invalid_design_council_text, field}}

  defp required_list_section(values, field) when is_list(values) do
    if length(values) > @max_list_items do
      {:error, {:design_council_section_overflow, field}}
    else
      values
      |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
        case required_section(item, field, @max_list_section_bytes) do
          {:ok, text} -> {:cont, {:ok, [text | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, acc} ->
          formatted = format_list(Enum.reverse(acc))

          if byte_size(formatted) <= @max_list_section_bytes do
            {:ok, formatted}
          else
            {:error, {:design_council_section_overflow, field}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp required_list_section(_values, field),
    do: {:error, {:invalid_design_council_text, field}}

  defp format_list([]), do: "- (none)"
  defp format_list(items), do: Enum.map_join(items, "\n", &("- " <> &1))

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end

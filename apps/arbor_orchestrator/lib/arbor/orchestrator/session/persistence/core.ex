defmodule Arbor.Orchestrator.Session.Persistence.Core do
  @moduledoc """
  Pure construction of ordered, provenance-bound Session turn entries.

  The persistence shell supplies timestamps and commits the returned pair. This
  module decides the final stored content blocks, source-owned metadata, and the
  monotonic taint labels bound to those exact blocks.
  """

  alias Arbor.Contracts.LLM.TokenUsage
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Contracts.Session.AssistantMessage

  @admitted_statuses [:success, :partial_success]
  @user_context_keys ["session.input", "session.query"]
  @assistant_text_context_keys ["session.response", "last_response"]
  @assistant_tool_context_keys ["session.tool_calls"]
  @partial_statuses [:interrupted, :cancelled, :failed]

  @type entry :: map()

  @doc "Build the exact user/assistant entry pair for one turn."
  @spec build_turn_entries(map()) :: {:ok, [entry()]} | {:error, atom()}
  def build_turn_entries(params) when is_map(params) do
    user_message = Map.fetch!(params, :user_message)
    assistant_message = Map.fetch!(params, :assistant_message)
    user_sent_at = Map.fetch!(params, :user_sent_at)
    assistant_completed_at = Map.fetch!(params, :assistant_completed_at)
    engagement_id = Map.get(params, :engagement_id)
    turn_count = Map.get(params, :turn_count, 0)
    run_result = Map.get(params, :run_result)

    user_content = user_message |> message_content() |> wrap_content()

    assistant_content =
      build_assistant_content(assistant_message.content, assistant_message.tool_calls)

    with %AssistantMessage{} <- assistant_message,
         {:ok, user_taint, assistant_taint} <-
           derive_turn_taints(
             message_content(user_message),
             assistant_message,
             run_result
           ),
         {:ok, user_envelope} <- bind_envelope(user_content, user_taint),
         {:ok, assistant_envelope} <- bind_envelope(assistant_content, assistant_taint) do
      user_entry = %{
        entry_type: "user",
        role: "user",
        content: user_content,
        timestamp: user_sent_at,
        metadata: %{
          "engagement_id" => engagement_id,
          "taint" => user_envelope
        }
      }

      assistant_entry = %{
        entry_type: "assistant",
        role: "assistant",
        content: assistant_content,
        model: assistant_message.model,
        stop_reason: assistant_message.finish_reason,
        token_usage: token_usage(assistant_message.usage),
        timestamp: assistant_completed_at,
        metadata:
          assistant_metadata(
            assistant_message,
            engagement_id,
            turn_count,
            assistant_envelope
          )
      }

      {:ok, [user_entry, assistant_entry]}
    else
      _ -> {:error, :durable_provenance_unavailable}
    end
  rescue
    _ -> {:error, :invalid_turn_entries}
  catch
    _, _ -> {:error, :invalid_turn_entries}
  end

  def build_turn_entries(_params), do: {:error, :invalid_turn_entries}

  @doc "Wrap text in the canonical SessionEntry content-block representation."
  @spec wrap_content(term()) :: list()
  def wrap_content(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]
  def wrap_content(content) when is_list(content), do: content
  def wrap_content(_content), do: []

  @doc "Build the assistant's final text and tool-use content blocks."
  @spec build_assistant_content(term(), term()) :: list()
  def build_assistant_content(text, tool_calls) when is_list(tool_calls) and tool_calls != [] do
    text_block = if text && text != "", do: [%{"type" => "text", "text" => text}], else: []

    tool_blocks =
      Enum.map(tool_calls, fn tool_call ->
        %{
          "type" => "tool_use",
          "id" => Map.get(tool_call, "id", Map.get(tool_call, :id)),
          "name" => Map.get(tool_call, "name", Map.get(tool_call, :name)),
          "input" => Map.get(tool_call, "input", Map.get(tool_call, :input, %{}))
        }
      end)

    text_block ++ tool_blocks
  end

  def build_assistant_content(text, _tool_calls), do: wrap_content(text)

  @doc "Rebuild public persistence rows as provenance-carrying Session messages."
  @spec restore_messages([term()]) :: [map()]
  def restore_messages(rows) when is_list(rows), do: Enum.map(rows, &restore_message/1)

  defp restore_message(entry) when is_map(entry) do
    {taint, taint_status} = restore_taint(entry)

    %{
      "role" => entry |> fetch_row_value(:role) |> normalize_role(),
      "content" => fetch_row_value(entry, :content) || "",
      "metadata" => normalize_metadata(fetch_row_value(entry, :metadata)),
      "taint" => taint,
      "taint_status" => taint_status
    }
  end

  defp restore_message(_entry), do: fallback_restored_message()

  defp restore_taint(entry) do
    case {fetch_row(entry, :taint), fetch_row(entry, :taint_status)} do
      {{:ok, taint}, {:ok, :verified}} ->
        canonical_or_invalid(taint, :verified)

      {{:ok, taint}, {:ok, :legacy_unlabeled}} ->
        exact_fallback_or_invalid(taint, TaintEnvelope.missing_fallback(), :legacy_unlabeled)

      {{:ok, taint}, {:ok, :invalid_durable_provenance}} ->
        exact_fallback_or_invalid(
          taint,
          TaintEnvelope.invalid_fallback(),
          :invalid_durable_provenance
        )

      {:error, :error} ->
        if metadata_has_taint?(fetch_row_value(entry, :metadata)) do
          {TaintEnvelope.invalid_fallback(), :invalid_durable_provenance}
        else
          {TaintEnvelope.missing_fallback(), :legacy_unlabeled}
        end

      _other ->
        {TaintEnvelope.invalid_fallback(), :invalid_durable_provenance}
    end
  end

  defp canonical_or_invalid(taint, status) do
    case Taint.canonicalize(taint) do
      {:ok, canonical} -> {canonical, status}
      {:error, _reason} -> {TaintEnvelope.invalid_fallback(), :invalid_durable_provenance}
    end
  end

  defp exact_fallback_or_invalid(taint, expected, status) do
    case Taint.canonicalize(taint) do
      {:ok, ^expected} -> {expected, status}
      _other -> {TaintEnvelope.invalid_fallback(), :invalid_durable_provenance}
    end
  end

  defp fallback_restored_message do
    %{
      "role" => nil,
      "content" => "",
      "metadata" => %{},
      "taint" => TaintEnvelope.invalid_fallback(),
      "taint_status" => :invalid_durable_provenance
    }
  end

  defp fetch_row(entry, key) do
    case Map.fetch(entry, key) do
      :error -> Map.fetch(entry, Atom.to_string(key))
      value -> value
    end
  end

  defp fetch_row_value(entry, key) do
    case fetch_row(entry, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp normalize_role(role) when is_atom(role), do: Atom.to_string(role)
  defp normalize_role(role) when is_binary(role), do: role
  defp normalize_role(_role), do: nil

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp metadata_has_taint?(metadata) when is_map(metadata) do
    Map.has_key?(metadata, "taint") or Map.has_key?(metadata, :taint)
  end

  defp metadata_has_taint?(_metadata), do: false

  defp derive_turn_taints(_user_content, %AssistantMessage{status: status}, _run_result)
       when status in @partial_statuses do
    with {:ok, user_taint} <- source_owned_partial_taint("session_partial_user_input"),
         {:ok, output_taint} <- source_owned_partial_taint("session_partial_llm_output"),
         {:ok, assistant_taint} <- Taint.join(user_taint, output_taint) do
      {:ok, user_taint, assistant_taint}
    end
  end

  defp derive_turn_taints(user_content, assistant_message, run_result) do
    with {:ok, context, taint_map} <- admitted_evidence(run_result),
         user_taint <- exact_alias_taint(context, taint_map, @user_context_keys, user_content),
         assistant_component_taints <-
           assistant_component_taints(context, taint_map, assistant_message),
         {:ok, assistant_taint} <-
           join_taints([user_taint | assistant_component_taints]) do
      {:ok, user_taint, assistant_taint}
    else
      _ ->
        fallback = TaintEnvelope.missing_fallback()
        {:ok, fallback, fallback}
    end
  end

  defp admitted_evidence(%{
         final_outcome: %{status: status},
         context: context,
         taint: taint_map
       })
       when status in @admitted_statuses and is_map(context) and is_map(taint_map),
       do: {:ok, context, taint_map}

  defp admitted_evidence(_run_result), do: {:error, :unadmitted_run_result}

  defp assistant_component_taints(context, taint_map, assistant_message) do
    text_taints =
      case assistant_message.content do
        text when is_binary(text) and text != "" ->
          [exact_alias_taint(context, taint_map, @assistant_text_context_keys, text)]

        _ ->
          []
      end

    tool_taints =
      case assistant_message.tool_calls do
        calls when is_list(calls) and calls != [] ->
          [exact_alias_taint(context, taint_map, @assistant_tool_context_keys, calls)]

        _ ->
          []
      end

    case text_taints ++ tool_taints do
      [] -> [TaintEnvelope.missing_fallback()]
      taints -> taints
    end
  end

  defp exact_alias_taint(context, taint_map, keys, expected_value) do
    labels =
      keys
      |> Enum.filter(fn key ->
        Map.has_key?(context, key) and Map.get(context, key) == expected_value
      end)
      |> Enum.map(&context_taint(taint_map, &1))

    case labels do
      [] -> TaintEnvelope.missing_fallback()
      _ -> join_or_invalid(labels)
    end
  end

  defp context_taint(taint_map, key) do
    case Map.fetch(taint_map, key) do
      {:ok, value} ->
        case Taint.canonicalize(value) do
          {:ok, taint} -> taint
          {:error, _reason} -> TaintEnvelope.invalid_fallback()
        end

      :error ->
        TaintEnvelope.missing_fallback()
    end
  end

  defp join_or_invalid(taints) do
    case join_taints(taints) do
      {:ok, taint} -> taint
      {:error, _reason} -> TaintEnvelope.invalid_fallback()
    end
  end

  defp join_taints(taints), do: Taint.join_many(taints)

  defp source_owned_partial_taint(source) do
    Taint.new(%{
      level: :untrusted,
      sensitivity: :restricted,
      sanitizations: 0,
      confidence: :unverified,
      source: source,
      chain: []
    })
  end

  defp bind_envelope(content, taint) do
    with {:ok, envelope} <- TaintEnvelope.new(content, taint),
         {:ok, persisted} <- TaintEnvelope.to_map(envelope) do
      {:ok, persisted}
    end
  end

  defp message_content(message) when is_map(message) do
    Map.get(message, "content", Map.get(message, :content))
  end

  defp message_content(_message), do: nil

  defp token_usage(nil), do: nil

  defp token_usage(usage) do
    if TokenUsage.empty?(usage), do: nil, else: TokenUsage.to_persistence(usage)
  end

  defp assistant_metadata(message, engagement_id, turn_count, envelope) do
    metadata = %{
      "engagement_id" => engagement_id,
      "turn_count" => turn_count + 1,
      "status" => to_string(message.status),
      "taint" => envelope
    }

    if message.status != :complete and not is_nil(message.interrupted_reason) do
      Map.put(metadata, "interrupted_reason", inspect(message.interrupted_reason))
    else
      metadata
    end
  end
end

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
  alias Arbor.Orchestrator.DurableJson

  @admitted_statuses [:success, :partial_success]
  @user_context_keys ["session.input", "session.query"]
  @assistant_text_context_keys ["session.response", "last_response"]
  @assistant_tool_context_keys ["session.tool_calls"]
  @partial_statuses [:interrupted, :cancelled, :failed]
  @partial_evidence_keys [:kind, :user_content, :user_taint]
  @prompt_roles ~w(system user assistant tool)
  @checkpoint_message_keys ["envelope", "payload", "status"]
  @checkpoint_message_domain "arbor.session.checkpoint.message.v2"
  @checkpoint_scope_keys ["agent_id", "current_engagement_id", "session_id"]
  @taint_statuses [:verified, :legacy_unlabeled, :invalid_durable_provenance]

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

  @doc "Build the labeled live Session projection for one admitted turn."
  @spec build_live_turn_messages(map()) ::
          {:ok,
           %{
             messages: [map()],
             user_message: map(),
             assistant_message: map() | nil
           }}
          | {:error, atom()}
  def build_live_turn_messages(params) when is_map(params) do
    history = Map.fetch!(params, :history)
    user_message = Map.fetch!(params, :user_message)
    assistant_projection = Map.get(params, :assistant_projection)
    assistant_message = Map.fetch!(params, :assistant_message)
    run_result = Map.get(params, :run_result)

    with true <- is_list(history),
         true <- is_map(user_message),
         true <- is_nil(assistant_projection) or is_map(assistant_projection),
         %AssistantMessage{} <- assistant_message,
         {:ok, user_taint, assistant_taint} <-
           derive_turn_taints(
             message_content(user_message),
             assistant_message,
             run_result
           ) do
      labeled_user = label_live_message(user_message, user_taint)

      labeled_assistant =
        if is_map(assistant_projection) do
          label_live_message(assistant_projection, assistant_taint)
        end

      messages = history ++ [labeled_user] ++ List.wrap(labeled_assistant)

      {:ok,
       %{
         messages: messages,
         user_message: labeled_user,
         assistant_message: labeled_assistant
       }}
    else
      _ -> {:error, :live_turn_provenance_unavailable}
    end
  rescue
    _ -> {:error, :invalid_live_turn}
  catch
    _, _ -> {:error, :invalid_live_turn}
  end

  def build_live_turn_messages(_params), do: {:error, :invalid_live_turn}

  @doc "Project Session messages to JSON-clean role/content maps for Engine and providers."
  @spec prompt_messages([term()]) :: [map()]
  def prompt_messages(messages) when is_list(messages) do
    Enum.reduce(messages, [], fn message, acc ->
      case prompt_message(message) do
        {:ok, projected} -> [projected | acc]
        :error -> acc
      end
    end)
    |> Enum.reverse()
  end

  def prompt_messages(_messages), do: []

  @doc "Join Session-owned history provenance into the out-of-band Engine taint map."
  @spec join_authoritative_history_taint(map(), [term()]) :: map()
  def join_authoritative_history_taint(initial_taint, messages)
      when is_map(initial_taint) and is_list(messages) and messages != [] do
    taints =
      [initial_context_taint(Map.get(initial_taint, "session.messages"))] ++
        Enum.map(messages, &authoritative_message_taint/1)

    joined =
      case Taint.join_many(taints) do
        {:ok, taint} -> taint
        {:error, _reason} -> TaintEnvelope.invalid_fallback()
      end

    Map.put(initial_taint, "session.messages", joined)
  end

  def join_authoritative_history_taint(initial_taint, _messages) when is_map(initial_taint),
    do: initial_taint

  def join_authoritative_history_taint(_initial_taint, _messages), do: %{}

  @doc "Capture exact process-local input taint for an in-flight partial turn."
  @spec build_partial_turn_evidence(map(), map(), term()) :: map()
  def build_partial_turn_evidence(values, initial_taint, user_content)
      when is_map(values) and is_map(initial_taint) do
    alias_labels =
      @user_context_keys
      |> Enum.filter(&(Map.get(values, &1) === user_content))
      |> Enum.map(&initial_context_taint(Map.get(initial_taint, &1)))

    message_labels =
      if current_user_in_messages?(Map.get(values, "session.messages"), user_content) do
        [initial_context_taint(Map.get(initial_taint, "session.messages"))]
      else
        []
      end

    user_taint =
      case alias_labels ++ message_labels do
        [] -> TaintEnvelope.missing_fallback()
        labels -> join_or_invalid(labels)
      end

    %{
      kind: :session_turn_start,
      user_content: user_content,
      user_taint: user_taint
    }
  end

  def build_partial_turn_evidence(_values, _initial_taint, user_content) do
    %{
      kind: :session_turn_start,
      user_content: user_content,
      user_taint: TaintEnvelope.invalid_fallback()
    }
  end

  @doc "Encode live Session messages as exact payload-bound checkpoint records."
  @spec encode_checkpoint_messages([term()], map()) ::
          {:ok, [map()]} | {:error, atom()}
  def encode_checkpoint_messages(messages, scope) when is_list(messages) do
    with {:ok, scope_binding} <- checkpoint_scope_binding(scope) do
      message_count = length(messages)

      messages
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {message, position}, {:ok, encoded} ->
        case encode_checkpoint_message(message, position, message_count, scope_binding) do
          {:ok, checkpoint_message} -> {:cont, {:ok, [checkpoint_message | encoded]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
        {:error, _reason} = error -> error
      end
    end
  rescue
    _ -> {:error, :invalid_checkpoint_messages}
  catch
    _, _ -> {:error, :invalid_checkpoint_messages}
  end

  def encode_checkpoint_messages(_messages, _scope),
    do: {:error, :invalid_checkpoint_messages}

  @doc "Strictly restore current checkpoint records or conservatively label legacy rows."
  @spec restore_checkpoint_messages(term(), map() | :missing) ::
          {:ok, [map()]} | {:error, atom()}
  def restore_checkpoint_messages(messages, scope) when is_list(messages) do
    with {:ok, scope_binding} <- checkpoint_scope_binding(scope) do
      message_count = length(messages)

      restored =
        messages
        |> Enum.with_index()
        |> Enum.map(fn {message, position} ->
          restore_checkpoint_message(message, position, message_count, scope_binding)
        end)

      {:ok, restored}
    end
  rescue
    _ -> {:error, :invalid_checkpoint_messages}
  catch
    _, _ -> {:error, :invalid_checkpoint_messages}
  end

  def restore_checkpoint_messages(_messages, _scope),
    do: {:error, :invalid_checkpoint_messages}

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

  defp encode_checkpoint_message(message, position, message_count, scope_binding)
       when is_map(message) and not is_struct(message) do
    raw_payload = checkpoint_payload(message)
    {taint, status} = checkpoint_label(message)
    persisted_status = Atom.to_string(status)

    with {:ok, payload_digest} <- DurableJson.project_and_digest(raw_payload),
         payload = payload_digest.projection,
         {:ok, descriptor} <-
           checkpoint_descriptor(
             payload_digest,
             persisted_status,
             position,
             message_count,
             scope_binding
           ),
         {:ok, envelope} <- TaintEnvelope.new(descriptor, taint),
         {:ok, persisted} <- TaintEnvelope.to_map(envelope) do
      {:ok,
       %{
         "payload" => payload,
         "envelope" => persisted,
         "status" => persisted_status
       }}
    else
      _ -> {:error, :checkpoint_provenance_unavailable}
    end
  end

  defp encode_checkpoint_message(_message, _position, _message_count, _scope_binding),
    do: {:error, :invalid_checkpoint_message}

  defp restore_checkpoint_message(message, position, message_count, scope_binding)
       when is_map(message) and not is_struct(message) do
    if checkpoint_wrapper_shaped?(message) do
      restore_current_checkpoint_message(message, position, message_count, scope_binding)
    else
      message
      |> checkpoint_payload()
      |> put_checkpoint_label(TaintEnvelope.missing_fallback(), :legacy_unlabeled)
    end
  end

  defp restore_checkpoint_message(_message, _position, _message_count, _scope_binding) do
    put_checkpoint_label(
      %{"role" => nil, "content" => ""},
      TaintEnvelope.invalid_fallback(),
      :invalid_durable_provenance
    )
  end

  defp restore_current_checkpoint_message(message, position, message_count, scope_binding) do
    with true <- exact_string_keys?(message, @checkpoint_message_keys),
         payload when is_map(payload) and not is_struct(payload) <- message["payload"],
         {:ok, payload_digest} <- DurableJson.project_and_digest(payload),
         true <- payload_digest.projection === payload,
         {:ok, status} <- normalize_persisted_taint_status(message["status"]),
         {:ok, descriptor} <-
           checkpoint_descriptor(
             payload_digest,
             message["status"],
             position,
             message_count,
             scope_binding
           ),
         {:ok, envelope} <- TaintEnvelope.verify(message["envelope"], descriptor),
         true <- valid_taint_status?(envelope.taint, status) do
      put_checkpoint_label(payload, envelope.taint, status)
    else
      _ ->
        message
        |> checkpoint_fallback_payload()
        |> put_checkpoint_label(
          TaintEnvelope.invalid_fallback(),
          :invalid_durable_provenance
        )
    end
  end

  defp checkpoint_scope_binding(:missing), do: {:ok, :missing}

  defp checkpoint_scope_binding(scope) when is_map(scope) and not is_struct(scope) do
    with true <- exact_string_keys?(scope, @checkpoint_scope_keys),
         session_id when is_binary(session_id) <- scope["session_id"],
         agent_id when is_binary(agent_id) <- scope["agent_id"],
         engagement_id when is_binary(engagement_id) or is_nil(engagement_id) <-
           scope["current_engagement_id"],
         {:ok, scope_digest} <- DurableJson.project_and_digest(scope),
         true <- scope_digest.projection === scope do
      durable_digest_descriptor(scope_digest)
    else
      _ -> {:error, :invalid_checkpoint_scope}
    end
  end

  defp checkpoint_scope_binding(_scope), do: {:error, :invalid_checkpoint_scope}

  defp checkpoint_descriptor(payload_digest, status, position, message_count, scope_binding)
       when is_integer(position) and position >= 0 and is_integer(message_count) and
              message_count > position and is_map(scope_binding) do
    with {:ok, payload_binding} <- durable_digest_descriptor(payload_digest) do
      {:ok,
       %{
         "domain" => @checkpoint_message_domain,
         "message_count" => message_count,
         "payload_digest" => payload_binding,
         "position" => position,
         "scope_digest" => scope_binding,
         "status" => status
       }}
    end
  end

  defp checkpoint_descriptor(
         _payload_digest,
         _status,
         _position,
         _message_count,
         _scope_binding
       ),
       do: {:error, :missing_checkpoint_scope}

  defp durable_digest_descriptor(%{
         encoding: encoding,
         digest_algorithm: digest_algorithm,
         sha256: sha256
       })
       when is_binary(encoding) and is_binary(digest_algorithm) and is_binary(sha256) do
    {:ok,
     %{
       "digest_algorithm" => digest_algorithm,
       "encoding" => encoding,
       "sha256" => sha256
     }}
  end

  defp durable_digest_descriptor(_digest), do: {:error, :invalid_durable_json_digest}

  defp checkpoint_payload(message) do
    Map.drop(message, [:taint, "taint", :taint_status, "taint_status"])
  end

  defp checkpoint_fallback_payload(message) do
    case fetch_alias(message, :payload) do
      {:ok, payload} when is_map(payload) and not is_struct(payload) ->
        checkpoint_payload(payload)

      _ ->
        %{"role" => nil, "content" => ""}
    end
  end

  defp checkpoint_label(message) do
    case {fetch_alias(message, :taint), fetch_alias(message, :taint_status)} do
      {:error, :error} ->
        {TaintEnvelope.missing_fallback(), :legacy_unlabeled}

      {{:ok, taint}, {:ok, status}} ->
        with {:ok, taint} <- Taint.canonicalize(taint),
             {:ok, status} <- normalize_taint_status(status),
             true <- valid_taint_status?(taint, status) do
          {taint, status}
        else
          _ -> {TaintEnvelope.invalid_fallback(), :invalid_durable_provenance}
        end

      _ ->
        {TaintEnvelope.invalid_fallback(), :invalid_durable_provenance}
    end
  end

  defp authoritative_message_taint(message) when is_map(message) do
    {taint, _status} = checkpoint_label(message)
    taint
  end

  defp authoritative_message_taint(_message), do: TaintEnvelope.invalid_fallback()

  defp initial_context_taint(%Taint{} = taint) do
    case Taint.canonicalize(taint) do
      {:ok, canonical} -> canonical
      {:error, _reason} -> TaintEnvelope.invalid_fallback()
    end
  end

  defp initial_context_taint(level) when level in [:trusted, :derived, :untrusted, :hostile],
    do: %Taint{level: level}

  defp initial_context_taint(nil), do: TaintEnvelope.missing_fallback()
  defp initial_context_taint(_taint), do: TaintEnvelope.invalid_fallback()

  defp current_user_in_messages?(messages, user_content) when is_list(messages) do
    case List.last(messages) do
      %{"role" => "user", "content" => content} -> content === user_content
      %{role: :user, content: content} -> content === user_content
      _ -> false
    end
  end

  defp current_user_in_messages?(_messages, _user_content), do: false

  defp put_checkpoint_label(payload, taint, status) do
    payload
    |> checkpoint_payload()
    |> Map.put("taint", taint)
    |> Map.put("taint_status", status)
  end

  defp checkpoint_wrapper_shaped?(message) do
    Enum.any?(["payload", :payload, "envelope", :envelope], &Map.has_key?(message, &1))
  end

  defp exact_string_keys?(value, expected) when is_map(value) and not is_struct(value) do
    Enum.all?(Map.keys(value), &is_binary/1) and Enum.sort(Map.keys(value)) == Enum.sort(expected)
  end

  defp exact_string_keys?(_value, _expected), do: false

  defp fetch_alias(message, key) do
    string_key = Atom.to_string(key)

    case {Map.fetch(message, key), Map.fetch(message, string_key)} do
      {{:ok, _value}, {:ok, _other}} -> :error
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, :error} -> :error
    end
  end

  defp normalize_taint_status(status) when status in @taint_statuses, do: {:ok, status}

  defp normalize_taint_status(status) when is_binary(status) do
    case status do
      "verified" -> {:ok, :verified}
      "legacy_unlabeled" -> {:ok, :legacy_unlabeled}
      "invalid_durable_provenance" -> {:ok, :invalid_durable_provenance}
      _ -> :error
    end
  end

  defp normalize_taint_status(_status), do: :error

  defp normalize_persisted_taint_status(status) when is_binary(status),
    do: normalize_taint_status(status)

  defp normalize_persisted_taint_status(_status), do: :error

  defp valid_taint_status?(_taint, :verified), do: true

  defp valid_taint_status?(taint, :legacy_unlabeled),
    do: taint == TaintEnvelope.missing_fallback()

  defp valid_taint_status?(taint, :invalid_durable_provenance),
    do: taint == TaintEnvelope.invalid_fallback()

  defp valid_taint_status?(_taint, _status), do: false

  defp label_live_message(message, taint) do
    message
    |> Map.drop([:taint, "taint", :taint_status, "taint_status"])
    |> Map.put("taint", taint)
    |> Map.put("taint_status", :verified)
  end

  defp prompt_message(message) when is_map(message) do
    with {:ok, role} <- unambiguous_message_field(message, :role),
         {:ok, role} <- normalize_prompt_role(role),
         {:ok, content} <- unambiguous_message_field(message, :content),
         true <- json_clean?(content) do
      {:ok, %{"role" => role, "content" => content}}
    else
      _ -> :error
    end
  end

  defp prompt_message(_message), do: :error

  defp unambiguous_message_field(message, key) do
    string_key = Atom.to_string(key)

    case {Map.fetch(message, key), Map.fetch(message, string_key)} do
      {{:ok, _value}, {:ok, _other}} -> :error
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, :error} -> :error
    end
  end

  defp normalize_prompt_role(role) when is_atom(role),
    do: role |> Atom.to_string() |> normalize_prompt_role()

  defp normalize_prompt_role(role) when role in @prompt_roles, do: {:ok, role}
  defp normalize_prompt_role(_role), do: :error

  defp json_clean?(value) when is_binary(value), do: String.valid?(value)

  defp json_clean?(value)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_clean?(value) when is_atom(value), do: true

  defp json_clean?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, nested} ->
      ((is_binary(key) and String.valid?(key)) or is_atom(key)) and json_clean?(nested)
    end)
  end

  defp json_clean?([]), do: true
  defp json_clean?([head | tail]), do: json_clean?(head) and json_clean?(tail)
  defp json_clean?(_value), do: false

  defp derive_turn_taints(
         user_content,
         %AssistantMessage{status: status} = assistant_message,
         run_result
       )
       when status in @partial_statuses do
    with {:ok, user_baseline} <- source_owned_partial_taint("session_partial_user_input"),
         {:ok, output_taint} <- source_owned_partial_taint("session_partial_llm_output"),
         {:ok, assistant_baseline} <- Taint.join(user_baseline, output_taint) do
      join_partial_evidence(
        user_content,
        assistant_message,
        run_result,
        user_baseline,
        assistant_baseline
      )
    end
  end

  defp derive_turn_taints(user_content, assistant_message, run_result) do
    with {:ok, user_taint, assistant_taint} <-
           derive_admitted_taints(user_content, assistant_message, run_result) do
      {:ok, user_taint, assistant_taint}
    else
      _ ->
        fallback = TaintEnvelope.missing_fallback()
        {:ok, fallback, fallback}
    end
  end

  defp join_partial_evidence(
         user_content,
         assistant_message,
         run_result,
         user_baseline,
         assistant_baseline
       ) do
    case derive_admitted_taints(user_content, assistant_message, run_result) do
      {:ok, user_evidence, assistant_evidence} ->
        with {:ok, user_taint} <- Taint.join(user_baseline, user_evidence),
             {:ok, assistant_taint} <- Taint.join(assistant_baseline, assistant_evidence) do
          {:ok, user_taint, assistant_taint}
        else
          _ -> invalid_turn_taints()
        end

      {:error, :unadmitted_run_result} ->
        join_partial_start_evidence(
          user_content,
          run_result,
          user_baseline,
          assistant_baseline
        )

      {:error, _reason} ->
        invalid_turn_taints()
    end
  end

  defp join_partial_start_evidence(
         user_content,
         evidence,
         user_baseline,
         assistant_baseline
       ) do
    case partial_start_user_taint(evidence, user_content) do
      {:ok, user_evidence} ->
        with {:ok, user_taint} <- Taint.join(user_baseline, user_evidence),
             {:ok, assistant_taint} <- Taint.join(assistant_baseline, user_evidence) do
          {:ok, user_taint, assistant_taint}
        else
          _ -> invalid_turn_taints()
        end

      :unavailable ->
        {:ok, user_baseline, assistant_baseline}

      :invalid ->
        invalid_turn_taints()
    end
  end

  defp partial_start_user_taint(evidence, user_content)
       when is_map(evidence) and map_size(evidence) == length(@partial_evidence_keys) do
    if Enum.sort(Map.keys(evidence)) == Enum.sort(@partial_evidence_keys) and
         evidence.kind == :session_turn_start and evidence.user_content === user_content do
      case Taint.canonicalize(evidence.user_taint) do
        {:ok, taint} -> {:ok, taint}
        {:error, _reason} -> :invalid
      end
    else
      :invalid
    end
  end

  defp partial_start_user_taint(%{kind: :session_turn_start}, _user_content), do: :invalid
  defp partial_start_user_taint(_evidence, _user_content), do: :unavailable

  defp derive_admitted_taints(user_content, assistant_message, run_result) do
    with {:ok, context, taint_map} <- admitted_evidence(run_result),
         user_taint <- exact_alias_taint(context, taint_map, @user_context_keys, user_content),
         assistant_component_taints <-
           assistant_component_taints(context, taint_map, assistant_message),
         {:ok, assistant_taint} <-
           join_taints([user_taint | assistant_component_taints]) do
      {:ok, user_taint, assistant_taint}
    end
  end

  defp invalid_turn_taints do
    fallback = TaintEnvelope.invalid_fallback()
    {:ok, fallback, fallback}
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

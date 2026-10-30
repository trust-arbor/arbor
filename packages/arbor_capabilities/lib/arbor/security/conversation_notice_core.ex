defmodule Arbor.Security.ConversationNoticeCore do
  @moduledoc """
  Pure, closed facts for native private-mailbox publication.

  Validation and digests are comparisons, never publication authority. The
  source/worker admission is separately held by the native notice broker.
  """
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}

  @scope_keys [:owner_id, :target_agent_id, :engagement_id]
  @value_keys [:notice_id, :recipient_subject_id, :kind, :text, :provenance]
  @param_keys [:mailbox_id, :notice_id, :kind, :text]
  @text_limit 32_768
  @provenance_limit 4_096
  # Reserve space for source scope, timestamp and bounded page/correlation
  # fields. Valid UTF-8 can expand sixfold when JSON encodes control bytes.
  @encoded_value_limit 120_000
  @scope_patterns %{
    owner_id: ~r/\Ahuman_[A-Za-z0-9_-]+\z/,
    target_agent_id: ~r/\Aagent_[A-Za-z0-9_-]+\z/,
    engagement_id: ~r/\Aeng_[0-9a-f]{32}\z/
  }

  def limits,
    do: %{
      text_bytes: @text_limit,
      provenance_bytes: @provenance_limit,
      encoded_value_bytes: @encoded_value_limit
    }

  def scope(value) do
    if exact?(value, @scope_keys) and
         Enum.all?(@scope_patterns, fn {key, pattern} -> identifier?(value[key], pattern) end),
       do: {:ok, value},
       else: {:error, :invalid_notice}
  end

  def params(value) do
    if exact?(value, @param_keys) and mailbox?(value.mailbox_id) and
         notice_id?(value.notice_id) and value.kind in ["notification", "progress"] and
         text?(value.text),
       do: {:ok, value},
       else: {:error, :invalid_notice}
  end

  def new(scope, subject, params, source_taints \\ nil) do
    with {:ok, scope} <- scope(scope),
         {:ok, params} <- params(params),
         true <- identifier?(subject, @scope_patterns.owner_id),
         value = Map.take(params, [:notice_id, :kind, :text]),
         value = Map.put(value, :recipient_subject_id, subject),
         {:ok, taint} <- source_taint(source_taints),
         {:ok, envelope} <- TaintEnvelope.new(provenance_payload(scope, value), taint),
         {:ok, persisted} <- TaintEnvelope.to_map(envelope) do
      value(
        scope,
        Map.put(value, :provenance, %{"origin" => "native_action", "taint" => persisted})
      )
    else
      _ -> {:error, :invalid_notice}
    end
  end

  def value(scope, value) do
    with {:ok, scope} <- scope(scope),
         true <- exact?(value, @value_keys),
         true <- notice_id?(value.notice_id),
         true <- identifier?(value.recipient_subject_id, @scope_patterns.owner_id),
         true <- value.kind in ["notification", "progress"] and text?(value.text),
         %{"origin" => "native_action", "taint" => persisted} = provenance <- value.provenance,
         true <- map_size(provenance) == 2,
         {:ok, bytes} <- Jason.encode(provenance),
         true <- byte_size(bytes) <= @provenance_limit,
         {:ok, envelope} <- TaintEnvelope.verify(persisted, provenance_payload(scope, value)),
         true <- retained_taint?(envelope.taint),
         :ok <- encoded_value_bound(value) do
      {:ok, value}
    else
      {:error, :notice_too_large} = error -> error
      _ -> {:error, :invalid_notice}
    end
  rescue
    _ -> {:error, :invalid_notice}
  end

  def payload(scope, value) do
    with {:ok, value} <- value(scope, value),
         {:ok, bytes} <-
           TaintEnvelope.canonical_json([
             "arbor.conversation.notice.publication.v1",
             scope.owner_id,
             scope.target_agent_id,
             scope.engagement_id,
             value.recipient_subject_id,
             value.notice_id,
             value.kind,
             value.text,
             value.provenance
           ]) do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_notice}
    end
  end

  def digest(scope, value) do
    with {:ok, bytes} <- payload(scope, value),
         do: {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  end

  def resource(scope, value) do
    with {:ok, value} <- value(scope, value) do
      {:ok,
       "arbor://comms/notice/publish/#{scope.target_agent_id}/#{value.recipient_subject_id}/#{scope.owner_id}/#{scope.engagement_id}"}
    end
  end

  def mailbox?(value), do: identifier?(value, ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, 128)
  def notice_id?(value), do: identifier?(value, ~r/\Anotice_[0-9a-f]{32}\z/, 39)

  # Inputs come from the private native execution frame, never action params.
  # Unknown metadata absorbs all dimensions. Only the classification survives;
  # private source/chain identifiers do not become mailbox payload metadata.
  def source_taint(source_taints) when is_list(source_taints) and source_taints != [] do
    with {:ok, floor} <- conservative_taint(),
         {:ok, joined} <- Taint.join_many([floor | source_taints]) do
      Taint.new(%{
        level: joined.level,
        sensitivity: joined.sensitivity,
        sanitizations: 0,
        confidence: :unverified,
        source: "native_conversation_notice",
        chain: []
      })
    else
      _ -> restricted_taint()
    end
  end

  def source_taint(_), do: restricted_taint()

  defp restricted_taint do
    Taint.new(%{
      level: :hostile,
      sensitivity: :restricted,
      sanitizations: 0,
      confidence: :unverified,
      source: "native_conversation_notice",
      chain: []
    })
  end

  defp retained_taint?(taint) do
    taint.level in [:untrusted, :hostile] and
      taint.sensitivity in [:internal, :confidential, :restricted] and
      taint.sanitizations == 0 and taint.confidence == :unverified and
      taint.source == "native_conversation_notice" and taint.chain == []
  end

  defp conservative_taint do
    Taint.new(%{
      level: :untrusted,
      sensitivity: :internal,
      sanitizations: 0,
      confidence: :unverified,
      source: "native_conversation_notice",
      chain: []
    })
  end

  defp provenance_payload(scope, value) do
    [
      "arbor.notice.provenance.v1",
      scope.owner_id,
      scope.target_agent_id,
      scope.engagement_id,
      value.recipient_subject_id,
      value.notice_id,
      value.kind,
      value.text
    ]
  end

  defp exact?(value, keys) when is_map(value) and not is_struct(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp exact?(_, _), do: false

  defp identifier?(value, pattern, maximum \\ 256)

  defp identifier?(value, pattern, maximum) when is_binary(value),
    do:
      byte_size(value) in 1..maximum//1 and String.valid?(value) and Regex.match?(pattern, value)

  defp identifier?(_, _, _), do: false

  defp text?(value) when is_binary(value),
    do: byte_size(value) in 1..@text_limit and String.valid?(value) and String.trim(value) != ""

  defp text?(_), do: false

  defp encoded_value_bound(value) do
    case Jason.encode(value) do
      {:ok, bytes} when byte_size(bytes) <= @encoded_value_limit -> :ok
      {:ok, _} -> {:error, :notice_too_large}
      _ -> {:error, :invalid_notice}
    end
  end
end

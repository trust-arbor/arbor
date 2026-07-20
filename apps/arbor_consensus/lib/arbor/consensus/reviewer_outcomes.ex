defmodule Arbor.Consensus.ReviewerOutcomes do
  @moduledoc false

  alias Arbor.Common.SensitiveData

  @max_outcomes 10
  @max_perspective_bytes 128
  @max_route_bytes 256
  @max_reason_bytes 512
  @redaction_lookahead_bytes 512
  @signed_64_min -9_223_372_036_854_775_808
  @signed_64_max 9_223_372_036_854_775_807
  @perspective_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @route_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/+@-]*\z/
  @statuses ~w(reported abstained failed missing invalid)
  @reason_codes ~w(
    valid_report
    deliberate_abstention
    branch_failed
    missing_context_updates
    missing_response
    malformed_response
    response_not_object
    ledger_invalid_report
    missing_branch
  )
  @votes ~w(approve reject abstain)

  @spec sanitize(term()) :: map()
  def sanitize(outcomes) when is_map(outcomes) and map_size(outcomes) <= @max_outcomes do
    outcomes
    |> Enum.filter(fn {perspective, outcome} ->
      valid_perspective?(perspective) and is_map(outcome)
    end)
    |> Enum.sort_by(fn {perspective, _outcome} -> perspective end)
    |> Map.new(fn {perspective, outcome} ->
      {perspective, sanitize_outcome(outcome)}
    end)
  end

  def sanitize(_outcomes), do: %{}

  defp sanitize_outcome(outcome) do
    %{}
    |> maybe_put("status", allowed_value(value(outcome, "status", :status), @statuses))
    |> maybe_put(
      "reason_code",
      allowed_value(value(outcome, "reason_code", :reason_code), @reason_codes)
    )
    |> maybe_put(
      "provider",
      bounded_route(value(outcome, "provider", :provider))
    )
    |> maybe_put("model", bounded_route(value(outcome, "model", :model)))
    |> maybe_put("reason", bounded_reason(value(outcome, "reason", :reason)))
    |> maybe_put(
      "submitted_vote",
      normalized_vote(value(outcome, "submitted_vote", :submitted_vote))
    )
    |> maybe_put(
      "effective_vote",
      normalized_vote(value(outcome, "effective_vote", :effective_vote))
    )
  end

  defp valid_perspective?(perspective) do
    is_binary(perspective) and perspective != "" and
      byte_size(perspective) <= @max_perspective_bytes and String.valid?(perspective) and
      Regex.match?(@perspective_pattern, perspective) and
      SensitiveData.redact_secrets(perspective) == perspective
  end

  defp bounded_route(value) do
    case bounded_redacted_text(value, @max_route_bytes) do
      "[REDACTED]" = redacted -> redacted
      route when is_binary(route) -> if Regex.match?(@route_pattern, route), do: route
      _other -> nil
    end
  end

  defp bounded_reason(nil), do: nil

  defp bounded_reason(reason) when is_binary(reason),
    do: bounded_redacted_text(reason, @max_reason_bytes)

  defp bounded_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> bounded_redacted_text(@max_reason_bytes)

  defp bounded_reason(reason)
       when is_integer(reason) and reason >= @signed_64_min and reason <= @signed_64_max,
       do: reason |> to_string() |> bounded_redacted_text(@max_reason_bytes)

  defp bounded_reason(reason) when is_float(reason),
    do: reason |> to_string() |> bounded_redacted_text(@max_reason_bytes)

  defp bounded_reason(_reason), do: nil

  defp bounded_redacted_text(value, maximum) when is_binary(value) and value != "" do
    value
    |> truncate_utf8_prefix(min(byte_size(value), maximum + @redaction_lookahead_bytes))
    |> case do
      nil -> nil
      prefix -> prefix |> redact_bounded_secrets() |> bounded_text(maximum)
    end
  end

  defp bounded_redacted_text(_value, _maximum), do: nil

  defp redact_bounded_secrets(prefix) do
    redacted =
      prefix
      |> SensitiveData.redact_secrets()
      |> redact_with_synthetic_terminator("\"")
      |> redact_with_synthetic_terminator("'")
      |> redact_with_synthetic_terminator("@")

    if redacted == prefix, do: prefix, else: "[REDACTED]"
  end

  defp redact_with_synthetic_terminator(text, terminator) do
    extended = text <> terminator <> "\n"
    redacted = SensitiveData.redact_secrets(extended)
    without_sentinel = binary_part(redacted, 0, byte_size(redacted) - 1)

    if without_sentinel == text <> terminator, do: text, else: without_sentinel
  end

  defp bounded_text(value, maximum) when is_binary(value) and value != "",
    do: truncate_utf8_prefix(value, min(byte_size(value), maximum))

  defp bounded_text(_value, _maximum), do: nil

  defp truncate_utf8_prefix(_value, size) when size <= 0, do: nil

  defp truncate_utf8_prefix(value, size) do
    prefix = binary_part(value, 0, size)

    if String.valid?(prefix) do
      prefix
    else
      truncate_utf8_prefix(value, size - 1)
    end
  end

  defp normalized_vote(vote) when vote in @votes, do: vote
  defp normalized_vote(vote) when vote in [:approve, :reject, :abstain], do: Atom.to_string(vote)
  defp normalized_vote(_vote), do: nil

  defp allowed_value(value, allowed) when is_binary(value) do
    if value in allowed, do: value, else: nil
  end

  defp allowed_value(value, allowed) when is_atom(value),
    do: value |> Atom.to_string() |> allowed_value(allowed)

  defp allowed_value(_value, _allowed), do: nil

  defp value(map, string_key, atom_key), do: Map.get(map, string_key) || Map.get(map, atom_key)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

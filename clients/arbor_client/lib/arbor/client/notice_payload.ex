defmodule Arbor.Client.NoticePayload do
  @moduledoc false
  @maximum_ordinal 9_223_372_036_854_775_807

  def encode(caller, target, options) do
    with true <- principal?(caller, ~r/\A(?:human|agent)_[A-Za-z0-9_-]+\z/),
         true <- principal?(target, ~r/\Aagent_[A-Za-z0-9_-]+\z/),
         true <- valid_options?(options) do
      Jason.encode!([
        "arbor.conversation.notices.v1",
        caller,
        target,
        [options[:before], options[:through], options[:limit]],
        options[:expected_engagement_id]
      ])
    else
      _ -> {:error, :invalid_notice_request}
    end
  rescue
    _ -> {:error, :invalid_notice_request}
  end

  defp valid_options?(options) when is_list(options) do
    Keyword.keyword?(options) and
      Keyword.has_key?(options, :expected_engagement_id) and
      length(options) == length(Enum.uniq(Keyword.keys(options))) and
      Enum.all?(options, fn
        {key, value} when key in [:before, :through] ->
          is_integer(value) and value in 1..@maximum_ordinal

        {:limit, value} ->
          is_integer(value) and value in 1..50

        {:expected_engagement_id, value} ->
          is_binary(value) and Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, value)

        _ ->
          false
      end)
  end

  defp valid_options?(_), do: false

  defp principal?(value, pattern),
    do:
      is_binary(value) and byte_size(value) in 1..256 and String.valid?(value) and
        Regex.match?(pattern, value)
end

defmodule ArborBreeze.Drafts do
  @moduledoc "Bounded pure cache of unsubmitted local drafts, scoped to Gateway, principal and target."
  @max_bytes 32_768
  def new(limit \\ 16) when is_integer(limit) and limit in 1..128,
    do: %{limit: limit, values: %{}, order: []}

  def get(cache, scope), do: Map.get(cache.values, scope, "")

  def put(cache, scope, text) when is_binary(text) and byte_size(text) <= @max_bytes do
    if scope?(scope) and String.valid?(text) do
      order = Enum.reject(cache.order, &(&1 == scope)) ++ [scope]
      order = Enum.take(order, -cache.limit)
      values = cache.values |> Map.put(scope, text) |> Map.take(order)
      %{cache | values: values, order: order}
    else
      cache
    end
  end

  def put(cache, _, _), do: cache
  def clear(cache), do: new(cache.limit)

  def scope?({url, principal, target}) do
    text?(url, 2_048) and id?(principal, ~r/\A(?:agent|human)_[A-Za-z0-9_-]+\z/) and
      id?(target, ~r/\Aagent_[A-Za-z0-9_-]+\z/)
  end

  def scope?(_), do: false
  defp id?(text, regex), do: text?(text, 256) and Regex.match?(regex, text)

  defp text?(text, max) when is_binary(text),
    do: byte_size(text) > 0 and byte_size(text) <= max and String.valid?(text)

  defp text?(_, _), do: false
end

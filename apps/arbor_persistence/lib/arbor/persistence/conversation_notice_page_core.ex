defmodule Arbor.Persistence.ConversationNoticePageCore do
  @moduledoc """
  Pure closed paging decisions for durable conversation notices. The shell
  supplies verified projections and a snapshot head. No text is truncated.
  """
  @maximum 9_223_372_036_854_775_807
  @byte_limit 129_024

  def options(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      bounds = %{
        limit: Keyword.get(opts, :limit, 20),
        before: Keyword.get(opts, :before),
        through: Keyword.get(opts, :through)
      }

      if length(keys) == length(Enum.uniq(keys)) and
           Enum.all?(keys, &(&1 in [:limit, :before, :through])) and
           is_integer(bounds.limit) and bounds.limit in 1..50 and
           ordinal_option?(opts, :before) and ordinal_option?(opts, :through),
         do: {:ok, bounds},
         else: {:error, :invalid_notice_options}
    else
      {:error, :invalid_notice_options}
    end
  end

  def page(scope, rows, head, through, limit) do
    base =
      Map.merge(scope, %{
        notices: [],
        head: head,
        through: through,
        has_older: false,
        next_before: nil,
        complete: true
      })

    pack(base, rows, limit, [])
  end

  # A maximum-sized metadata envelope must fit a single full record before it
  # can be admitted. Escaping can make a 32KiB UTF8 string much larger on wire.
  def fits_record?(scope, value) do
    record =
      Map.take(value, [:notice_id, :recipient_subject_id, :kind, :text, :provenance])
      |> Map.merge(%{ordinal: @maximum, created_at: "9999-12-31T23:59:59.999999Z"})

    base =
      Map.merge(scope, %{
        notices: [record],
        head: @maximum,
        through: @maximum,
        has_older: true,
        next_before: @maximum,
        complete: true
      })

    fits?(base)
  end

  defp pack(base, [], _remaining, included), do: {:ok, finish(base, included, false)}
  defp pack(base, _rows, 0, included), do: {:ok, finish(base, included, true)}

  defp pack(base, [row | rest], remaining, included) do
    candidate = finish(base, [row | included], rest != [])

    if fits?(candidate) do
      pack(base, rest, remaining - 1, [row | included])
    else
      case included do
        [] -> {:error, :invalid_notice_record}
        _ -> {:ok, finish(base, included, true)}
      end
    end
  end

  defp finish(base, included, more) do
    notices = Enum.reverse(included)

    Map.merge(base, %{
      notices: notices,
      has_older: more,
      next_before: if(more and included != [], do: hd(included).ordinal, else: nil)
    })
  end

  defp fits?(page), do: byte_size(Jason.encode!(page)) <= @byte_limit

  defp ordinal_option?(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> true
      {:ok, value} -> is_integer(value) and value in 1..@maximum
    end
  end
end

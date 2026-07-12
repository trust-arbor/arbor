defmodule Arbor.AI.Timeout do
  @moduledoc false

  @maximum_timeout_ms 4_294_967_295
  @max_options 128
  @deadline_key :deadline_ms
  @signed_64_min -9_223_372_036_854_775_808
  @signed_64_max 9_223_372_036_854_775_807

  @spec start_deadline(term(), pos_integer() | :infinity) ::
          {:ok, keyword(), pos_integer() | :infinity} | {:error, term()}
  def start_deadline(opts, default) do
    with {:ok, opts, timeout} <- normalize(opts, default),
         {:ok, supplied_deadlines} <- deadline_values(opts),
         :ok <- validate_deadlines(supplied_deadlines) do
      own_deadline = deadline_from_timeout(timeout)
      deadline = strictest_deadline([own_deadline | supplied_deadlines])

      normalized =
        opts
        |> Enum.reject(fn {key, _value} -> key == @deadline_key end)
        |> Keyword.put(@deadline_key, deadline)

      {:ok, normalized, timeout}
    end
  end

  @spec remaining(term()) ::
          {:ok, keyword(), pos_integer() | :infinity} | {:error, term()}
  def remaining(opts) do
    with {:ok, opts, timeout} <- normalize(opts, :infinity),
         {:ok, deadlines} <- deadline_values(opts),
         :ok <- validate_deadlines(deadlines),
         deadline = strictest_deadline(deadlines),
         {:ok, remaining} <- remaining_timeout(deadline, timeout) do
      normalized =
        opts
        |> Enum.reject(fn {key, _value} -> key == @deadline_key end)
        |> Keyword.put(@deadline_key, deadline)
        |> Keyword.put(:timeout, remaining)

      {:ok, normalized, remaining}
    end
  end

  @spec ensure_active(term()) :: :ok | {:error, :timeout | term()}
  def ensure_active(opts) do
    case remaining(opts) do
      {:ok, _opts, _remaining} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec deadline(term()) :: {:ok, integer() | :infinity} | {:error, term()}
  def deadline(opts) do
    with {:ok, deadlines} <- deadline_values(opts),
         :ok <- validate_deadlines(deadlines) do
      {:ok, strictest_deadline(deadlines)}
    end
  end

  @spec completed_before_deadline?(integer(), integer() | :infinity) :: boolean()
  def completed_before_deadline?(_completed_at, :infinity), do: true

  def completed_before_deadline?(completed_at, deadline)
      when is_integer(completed_at) and is_integer(deadline),
      do: completed_at <= deadline

  def completed_before_deadline?(_completed_at, _deadline), do: false

  @spec normalize(term(), pos_integer() | :infinity, atom()) ::
          {:ok, keyword(), pos_integer() | :infinity} | {:error, term()}
  def normalize(opts, default, canonical_key \\ :timeout) when is_atom(canonical_key) do
    keys = Arbor.LLM.timeout_option_keys()

    with {:ok, timeout} <- select(opts, keys, default, 1, true),
         {:ok, options} <- option_list(opts, [], 0) do
      normalized =
        options
        |> Enum.reject(fn {key, _value} -> key in keys end)
        |> Keyword.put(canonical_key, timeout)

      {:ok, normalized, timeout}
    end
  end

  @spec normalize_key(term(), atom(), pos_integer() | non_neg_integer() | :infinity, keyword()) ::
          {:ok, keyword(), pos_integer() | non_neg_integer() | :infinity} | {:error, term()}
  def normalize_key(opts, key, default, config \\ []) when is_atom(key) do
    minimum = Keyword.get(config, :minimum, 1)
    allow_infinity? = Keyword.get(config, :allow_infinity, false)

    with {:ok, timeout} <- select(opts, [key], default, minimum, allow_infinity?),
         {:ok, options} <- option_list(opts, [], 0) do
      normalized =
        options
        |> Enum.reject(fn {option_key, _value} -> option_key == key end)
        |> Keyword.put(key, timeout)

      {:ok, normalized, timeout}
    end
  end

  @spec select(term(), [atom()], term(), non_neg_integer(), boolean()) ::
          {:ok, non_neg_integer() | :infinity} | {:error, term()}
  def select(opts, keys, default, minimum \\ 1, allow_infinity? \\ false)
      when is_list(keys) and is_integer(minimum) and minimum >= 0 and
             is_boolean(allow_infinity?) do
    with true <- Enum.all?(keys, &is_atom/1) or {:error, :invalid_timeout_aliases},
         {:ok, options} <- option_list(opts, [], 0),
         values = values_for_keys(options, keys),
         selected = if(values == [], do: [default], else: values),
         :ok <- validate_values(selected, minimum, allow_infinity?) do
      finite = Enum.filter(selected, &is_integer/1)
      {:ok, if(finite == [], do: :infinity, else: Enum.min(finite))}
    end
  end

  defp values_for_keys(options, keys) do
    Enum.reduce(options, [], fn {key, value}, acc ->
      if key in keys, do: [value | acc], else: acc
    end)
  end

  defp deadline_values(opts) do
    with {:ok, options} <- option_list(opts, [], 0) do
      {:ok, values_for_keys(options, [@deadline_key])}
    end
  end

  defp validate_deadlines(values) do
    latest = System.monotonic_time(:millisecond) + @maximum_timeout_ms

    valid? = fn
      :infinity ->
        true

      value when is_integer(value) ->
        value >= @signed_64_min and value <= @signed_64_max and value <= latest

      _value ->
        false
    end

    if Enum.all?(values, valid?),
      do: :ok,
      else: {:error, :invalid_deadline}
  end

  defp deadline_from_timeout(:infinity), do: :infinity

  defp deadline_from_timeout(timeout) when is_integer(timeout),
    do: System.monotonic_time(:millisecond) + timeout

  defp strictest_deadline([]), do: :infinity

  defp strictest_deadline(deadlines) do
    case Enum.reject(deadlines, &(&1 == :infinity)) do
      [] -> :infinity
      finite -> Enum.min(finite)
    end
  end

  defp remaining_timeout(:infinity, timeout), do: {:ok, timeout}

  defp remaining_timeout(deadline, timeout) when is_integer(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 -> {:error, :timeout}
      timeout == :infinity -> {:ok, remaining}
      is_integer(timeout) -> {:ok, min(timeout, remaining)}
      true -> {:error, :invalid_timeout}
    end
  end

  defp validate_values(values, minimum, allow_infinity?) do
    valid? = fn
      :infinity -> allow_infinity?
      value when is_integer(value) -> value >= minimum and value <= @maximum_timeout_ms
      _value -> false
    end

    if Enum.all?(values, valid?),
      do: :ok,
      else: {:error, {:invalid_timeout, {minimum, @maximum_timeout_ms}}}
  end

  defp option_list([], acc, _count), do: {:ok, Enum.reverse(acc)}

  defp option_list(_opts, _acc, count) when count >= @max_options,
    do: {:error, {:invalid_options, :too_many_options}}

  defp option_list([{key, value} | rest], acc, count) when is_atom(key),
    do: option_list(rest, [{key, value} | acc], count + 1)

  defp option_list(_improper_or_non_keyword, _acc, _count),
    do: {:error, {:invalid_options, :keyword_required}}
end

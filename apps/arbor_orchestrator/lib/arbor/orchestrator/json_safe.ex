defmodule Arbor.Orchestrator.JsonSafe do
  @moduledoc """
  Coerce arbitrary Elixir terms into something `Jason.encode/1` can serialize.

  Used at JSON serialization boundaries that carry pipeline data of unknown shape
  — `status.json` audit dumps and the durable event log — where a non-encodable
  term (a typed struct without a `Jason.Encoder`, a pid, a reference, a function,
  a tuple) must NOT crash the run. These sinks are audit/observability records
  that are never read back to drive execution, so lossy coercion is correct: the
  alternative (an unhandled `Protocol.UndefinedError` mid-run) is strictly worse.

  Do NOT use this for data that must round-trip losslessly (e.g. resume
  checkpoints) — there, keep the data JSON-clean or use a lossless encoding.
  """

  # JSON-friendly date/time structs Jason already encodes — leave intact.
  @passthrough_structs [DateTime, Date, Time, NaiveDateTime]

  @doc """
  Recursively coerce `term` into a JSON-encodable shape.

  - JSON-friendly date/time structs pass through untouched.
  - Any other struct is flattened to a plain map (its fields recursed).
  - Maps recurse over values (non-string/atom keys become inspect strings).
  - Lists recurse; tuples become lists.
  - pids / references / functions / ports become inspect strings.
  - Everything else (numbers, strings, atoms, booleans, nil) passes through.
  """
  @spec coerce(term()) :: term()
  def coerce(%mod{} = v) when mod in @passthrough_structs, do: v
  def coerce(%_{} = struct), do: struct |> Map.from_struct() |> coerce()

  def coerce(v) when is_map(v),
    do: Map.new(v, fn {k, val} -> {coerce_key(k), coerce(val)} end)

  def coerce(v) when is_list(v), do: Enum.map(v, &coerce/1)
  def coerce(v) when is_tuple(v), do: v |> Tuple.to_list() |> coerce()

  def coerce(v) when is_pid(v) or is_reference(v) or is_function(v) or is_port(v),
    do: inspect(v)

  def coerce(v), do: v

  defp coerce_key(k) when is_binary(k) or is_atom(k), do: k
  defp coerce_key(k), do: inspect(k)
end

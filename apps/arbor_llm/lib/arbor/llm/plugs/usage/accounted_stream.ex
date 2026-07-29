defmodule Arbor.LLM.Plugs.Usage.AccountedStream do
  @moduledoc false

  # Internal Enumerable wrapper that carries streaming usage provenance without
  # changing the public stream or middleware contracts. Callers and middleware
  # still see an ordinary event enumerable; only Usage/Client peel the
  # provenance for a single post-collection finalizer. Exactly-once emission is
  # enforced by a GC-owned `:atomics` finalize_gate embedded in provenance and
  # preserved unchanged through Client.stream / OwnedStream / Stream wrappers,
  # so repeated or concurrent collection still cannot double-bill even when
  # callers discard finalize_streaming/3's returned map.

  defstruct [:source, :provenance]

  @type t :: %__MODULE__{
          source: Enumerable.t(),
          provenance: map()
        }

  @spec new(Enumerable.t(), map()) :: t()
  def new(source, provenance) when is_map(provenance) do
    %__MODULE__{source: source, provenance: provenance}
  end
end

defimpl Enumerable, for: Arbor.LLM.Plugs.Usage.AccountedStream do
  def reduce(%{source: source}, acc, fun), do: Enumerable.reduce(source, acc, fun)
  def count(%{source: source}), do: Enumerable.count(source)
  def member?(%{source: source}, value), do: Enumerable.member?(source, value)
  def slice(%{source: source}), do: Enumerable.slice(source)
end

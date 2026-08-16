defmodule Arbor.Commands.SafeRecoveryArtifact.CleanupPlan do
  @moduledoc false

  # Pure reducer over plain data only -- no fun/MFA/module/backend parameter
  # anywhere in this module. Production (ComposeShell) and tests
  # (ComposeFactInterpreter) each own a separate, hardcoded loop that walks
  # this plan and dispatches the emitted `tag` to real Shell/SourceStaging
  # calls or to fixture lookups respectively; no function value ever crosses
  # that boundary.

  @order [{:build, :b}, {:source, :b}, {:build, :a}, {:source, :a}]

  @type tag :: {:build, :a | :b} | {:source, :a | :b}
  @type cursor :: %{remaining: [tag()], skip_source: %{a: boolean(), b: boolean()}}

  @spec init() :: cursor()
  def init, do: %{remaining: @order, skip_source: %{a: false, b: false}}

  @spec next(map(), cursor()) :: {:cleanup, tag(), cursor()} | :done
  def next(_ledger, %{remaining: []}), do: :done

  def next(ledger, %{remaining: [tag | rest]} = cursor) do
    if emit?(ledger, cursor, tag) do
      {:cleanup, tag, %{cursor | remaining: rest}}
    else
      next(ledger, %{cursor | remaining: rest})
    end
  end

  @spec record(map(), cursor(), tag(), term()) :: {map(), cursor()}
  def record(ledger, cursor, {:build, slot} = _tag, :ok) do
    {put_in(ledger, [:build, slot], :none), cursor}
  end

  def record(ledger, cursor, {:build, slot} = _tag, _other_result) do
    {ledger, put_in(cursor, [:skip_source, slot], true)}
  end

  def record(ledger, cursor, {:source, slot} = _tag, :ok) do
    {put_in(ledger, [:source, slot], :none), cursor}
  end

  def record(
        ledger,
        cursor,
        {:source, slot} = _tag,
        {:error, {:cleanup_retained, _reason, identity}}
      ) do
    {put_in(ledger, [:source, slot], {:retained, identity}), cursor}
  end

  def record(ledger, cursor, {:source, _slot} = _tag, _other_result) do
    {ledger, cursor}
  end

  # Tags only -- never the underlying resource (lease handle, identity map).
  # Callers use this only to decide delete-vs-persist; the resource value
  # itself must never travel outside the ledger.
  @spec pending(map()) :: [tag()]
  def pending(ledger) do
    for kind <- [:build, :source],
        slot <- [:a, :b],
        resource = get_in(ledger, [kind, slot]),
        resource != :none do
      {kind, slot}
    end
  end

  defp emit?(ledger, _cursor, {:build, slot}) do
    get_in(ledger, [:build, slot]) != :none
  end

  defp emit?(ledger, cursor, {:source, slot}) do
    get_in(ledger, [:source, slot]) != :none and not cursor.skip_source[slot]
  end
end

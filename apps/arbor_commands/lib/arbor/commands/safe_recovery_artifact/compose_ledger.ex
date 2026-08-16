defmodule Arbor.Commands.SafeRecoveryArtifact.ComposeLedger do
  @moduledoc false

  # Authoritative owner-process ledger for the two-build composer. Backed by
  # the Process dictionary under one fixed key so at most one unresolved
  # cleanup episode can exist per owner process at a time (compose/1 checks
  # try_acquire/1 and fails closed with :cleanup_ledger_busy otherwise).

  @ledger_key {__MODULE__, :ledger}

  @type resource :: :none | {:live, term()} | {:retained, term()}

  @type t :: %{
          token: binary(),
          preserved_outcome: :unset | term(),
          source: %{a: resource(), b: resource()},
          build: %{a: resource(), b: resource()}
        }

  @spec try_acquire(binary()) :: :ok | :busy
  def try_acquire(token) when is_binary(token) do
    case Process.get(@ledger_key) do
      nil ->
        Process.put(@ledger_key, initial(token))
        :ok

      _existing ->
        :busy
    end
  end

  @spec fetch() :: {:ok, t()} | :error
  def fetch do
    case Process.get(@ledger_key) do
      nil -> :error
      ledger -> {:ok, ledger}
    end
  end

  @spec persist(t()) :: :ok
  def persist(ledger) when is_map(ledger) do
    Process.put(@ledger_key, ledger)
    :ok
  end

  @spec delete() :: :ok
  def delete do
    Process.delete(@ledger_key)
    :ok
  end

  @spec set_preserved_outcome_once(t(), term()) :: t()
  def set_preserved_outcome_once(%{preserved_outcome: :unset} = ledger, outcome) do
    %{ledger | preserved_outcome: outcome}
  end

  def set_preserved_outcome_once(ledger, _outcome), do: ledger

  # Called from the acquisition sites (perform_effect) the instant a source
  # lease, a C1 cleanup-retained identity, or a build handle returns -- always
  # fetch-mutate-persist in one call so the ledger is correct even if a later
  # step raises before returning.
  @spec record_source(:a | :b, resource()) :: :ok
  def record_source(slot, value) when slot in [:a, :b] do
    {:ok, ledger} = fetch()
    persist(put_in(ledger, [:source, slot], value))
  end

  @spec record_build(:a | :b, resource()) :: :ok
  def record_build(slot, value) when slot in [:a, :b] do
    {:ok, ledger} = fetch()
    persist(put_in(ledger, [:build, slot], value))
  end

  defp initial(token) do
    %{
      token: token,
      preserved_outcome: :unset,
      source: %{a: :none, b: :none},
      build: %{a: :none, b: :none}
    }
  end
end

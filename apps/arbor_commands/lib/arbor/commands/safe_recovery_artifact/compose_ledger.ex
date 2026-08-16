defmodule Arbor.Commands.SafeRecoveryArtifact.ComposeLedger do
  @moduledoc false

  # Authoritative owner-process ledger for the two-build composer. Backed by
  # the Process dictionary under a domain-scoped key -- :production (real
  # Arbor.Shell/SourceStaging resources, driven only by ComposeShell) and
  # :fact (test-only fixture placeholders, driven only by
  # ComposeFactInterpreter) are two entirely disjoint storage slots. This is
  # a security boundary, not just a naming convention: a receipt minted in
  # one domain must never be resolvable by looking up the other domain's
  # slot, so a synthetic fixture cleanup reply can never be mistaken for a
  # real Arbor.Shell release. Each domain still allows at most one
  # unresolved cleanup episode per owner process (try_acquire/2 fails closed
  # with :busy otherwise).

  @type domain :: :production | :fact

  @type resource :: :none | {:live, term()} | {:retained, term()}

  @type t :: %{
          token: binary(),
          preserved_outcome: :unset | term(),
          source: %{a: resource(), b: resource()},
          build: %{a: resource(), b: resource()}
        }

  @spec try_acquire(domain(), binary()) :: :ok | :busy
  def try_acquire(domain, token) when domain in [:production, :fact] and is_binary(token) do
    case Process.get(key(domain)) do
      nil ->
        Process.put(key(domain), initial(token))
        :ok

      _existing ->
        :busy
    end
  end

  @spec fetch(domain()) :: {:ok, t()} | :error
  def fetch(domain) when domain in [:production, :fact] do
    case Process.get(key(domain)) do
      nil -> :error
      ledger -> {:ok, ledger}
    end
  end

  @spec persist(domain(), t()) :: :ok
  def persist(domain, ledger) when domain in [:production, :fact] and is_map(ledger) do
    Process.put(key(domain), ledger)
    :ok
  end

  @spec delete(domain()) :: :ok
  def delete(domain) when domain in [:production, :fact] do
    Process.delete(key(domain))
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
  @spec record_source(domain(), :a | :b, resource()) :: :ok
  def record_source(domain, slot, value) when slot in [:a, :b] do
    {:ok, ledger} = fetch(domain)
    persist(domain, put_in(ledger, [:source, slot], value))
  end

  @spec record_build(domain(), :a | :b, resource()) :: :ok
  def record_build(domain, slot, value) when slot in [:a, :b] do
    {:ok, ledger} = fetch(domain)
    persist(domain, put_in(ledger, [:build, slot], value))
  end

  defp key(domain), do: {__MODULE__, domain}

  defp initial(token) do
    %{
      token: token,
      preserved_outcome: :unset,
      source: %{a: :none, b: :none},
      build: %{a: :none, b: :none}
    }
  end
end

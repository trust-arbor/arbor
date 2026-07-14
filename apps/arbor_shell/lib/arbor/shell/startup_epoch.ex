defmodule Arbor.Shell.StartupEpoch do
  @moduledoc false

  # Application boot-epoch persistence for permanent rest_for_one children.
  #
  # Stores only closed status markers and internal SHA-256 fingerprints of
  # caller terms — never raw bindings, identities, paths, or digests.
  # Independent authorities share one application epoch via opaque references
  # while remaining isolated by namespace.

  @type namespace :: atom()
  @type epoch :: reference() | nil
  @type closed_status :: :unsupported | :unavailable
  @type status ::
          :unbound
          | :bound
          | :poisoned
          | {:sealed, closed_status()}

  @type bind_result :: :bound | :matched | :poisoned | :sealed
  @type seal_result :: :sealed | :poisoned | :bound

  @sha256_bytes 32
  @closed_statuses [:unsupported, :unavailable]

  @doc false
  @spec status(namespace(), epoch()) :: status()
  def status(namespace, epoch) when is_atom(namespace) do
    case load(namespace, epoch) do
      :unbound -> :unbound
      :poisoned -> :poisoned
      {:bound, _fingerprint} -> :bound
      {:sealed, closed} -> {:sealed, closed}
      :corrupt -> poison_and_return(namespace, epoch, :poisoned)
    end
  end

  @doc false
  @spec bind(namespace(), epoch(), term()) :: bind_result()
  def bind(namespace, epoch, term) when is_atom(namespace) do
    fingerprint = fingerprint(term)

    case load(namespace, epoch) do
      :unbound ->
        case store(namespace, epoch, {:bound, fingerprint}) do
          :ok -> :bound
          :noop -> :bound
        end

      {:bound, ^fingerprint} ->
        :matched

      {:bound, _other} ->
        poison_and_return(namespace, epoch, :poisoned)

      :poisoned ->
        :poisoned

      {:sealed, _closed} ->
        :sealed

      :corrupt ->
        poison_and_return(namespace, epoch, :poisoned)
    end
  end

  @doc false
  @spec seal(namespace(), epoch(), closed_status()) :: seal_result()
  def seal(namespace, epoch, closed)
      when is_atom(namespace) and closed in @closed_statuses do
    case load(namespace, epoch) do
      :unbound ->
        case store(namespace, epoch, {:sealed, closed}) do
          :ok -> :sealed
          :noop -> :sealed
        end

      {:sealed, ^closed} ->
        :sealed

      {:sealed, _other} ->
        poison_and_return(namespace, epoch, :poisoned)

      {:bound, _fingerprint} ->
        :bound

      :poisoned ->
        :poisoned

      :corrupt ->
        poison_and_return(namespace, epoch, :poisoned)
    end
  end

  @doc false
  @spec poison(namespace(), epoch()) :: :ok
  def poison(namespace, epoch) when is_atom(namespace) do
    _ = store(namespace, epoch, :poisoned)
    :ok
  end

  @doc false
  @spec clear(namespace(), epoch()) :: :ok
  def clear(namespace, nil) when is_atom(namespace), do: :ok

  def clear(namespace, epoch) when is_atom(namespace) and is_reference(epoch) do
    :persistent_term.erase(key(namespace, epoch))
    :ok
  end

  # --- Internal storage (fingerprints / closed markers only) -----------------

  defp load(_namespace, nil), do: :unbound

  defp load(namespace, epoch) when is_reference(epoch) do
    case :persistent_term.get(key(namespace, epoch), :unbound) do
      :unbound ->
        :unbound

      :poisoned ->
        :poisoned

      {:bound, fingerprint}
      when is_binary(fingerprint) and byte_size(fingerprint) == @sha256_bytes ->
        {:bound, fingerprint}

      {:sealed, closed} when closed in @closed_statuses ->
        {:sealed, closed}

      _other ->
        :corrupt
    end
  end

  defp store(_namespace, nil, _value), do: :noop

  defp store(namespace, epoch, value) when is_reference(epoch) do
    :persistent_term.put(key(namespace, epoch), value)
    :ok
  end

  defp poison_and_return(namespace, epoch, result) do
    _ = store(namespace, epoch, :poisoned)
    result
  end

  defp fingerprint(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp key(namespace, epoch), do: {__MODULE__, namespace, epoch}
end

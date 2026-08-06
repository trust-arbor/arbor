defmodule Arbor.Security.TestBootstrap do
  @moduledoc """
  Starts the security stores that capability grants and identity checks need
  under ExUnit.

  Call once from a consumer app's `test/test_helper.exs`:

      Arbor.Security.TestBootstrap.start!()

  ## Why this exists

  `config/test.exs` sets `start_children: false` for the security app so the
  suite cannot collide with a running dev server, leaving its supervisor empty.
  `Application.ensure_all_started/1` is therefore not enough.

  Since capability replacement was made durable (`206d06b5d`, 2026-08-06),
  `Arbor.Security.grant/1` fails without the durable capability store — and
  fails with a compound error that names replacement bookkeeping rather than the
  missing store:

      {:error, {:capability_replacement_outcome_unknown,
                %{original: :capability_store_unavailable, ...}}}

  Six apps' test_helpers start `CapabilityStore`, but only four also start the
  `BufferedStore`s behind it, so `arbor_consensus` and `arbor_orchestrator`
  carry the same latent gap. That divergence is the defect this prevents; the
  gateway breakage was just what made it visible.

  ## Why this lives in `lib/` (not `test/support`)

  Umbrella apps don't share each other's `test/support` paths, and at least six
  apps need this. Same reasoning and same precedent as
  `Arbor.Persistence.DatabaseCase` and `Arbor.Memory.TestBootstrap`. It is only
  ever exercised under ExUnit; in a release it is an inert module.
  """

  require Logger

  @stores [
    {:arbor_security_capabilities, "capabilities"},
    {:arbor_security_identities, "identities"},
    {:arbor_security_signing_keys, "signing_keys"}
  ]

  @doc """
  Start the security stores and supporting processes.

  Idempotent. Returns `:ok` when the work was done, or `:skipped` when
  `Arbor.Security.Supervisor` is not running — a distinguishable value rather
  than a silent no-op, so "nothing ran" cannot be mistaken for "everything is
  fine".
  """
  @spec start!(keyword()) :: :ok | :skipped
  def start!(_opts \\ []) do
    _ = Application.ensure_all_started(:arbor_security)

    if Process.whereis(Arbor.Security.Supervisor) do
      ensure_stores!()
      ensure_children!()
      :ok
    else
      Logger.warning(
        "[Arbor.Security.TestBootstrap] Arbor.Security.Supervisor is not running; " <>
          "capability grants will fail with :capability_store_unavailable"
      )

      :skipped
    end
  end

  defp ensure_stores! do
    backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    for {name, collection} <- @stores do
      spec =
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: name, backend: backend, write_mode: :sync, collection: collection},
          id: name
        )

      start_child!(spec)
    end

    :ok
  end

  defp ensure_children! do
    for spec <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []}
        ] do
      start_child!(spec)
    end

    :ok
  end

  defp start_child!(spec) do
    case Supervisor.start_child(Arbor.Security.Supervisor, spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, :already_present} -> :ok
      {:error, reason} -> raise "TestBootstrap: #{inspect(spec)} failed: #{inspect(reason)}"
    end
  end
end

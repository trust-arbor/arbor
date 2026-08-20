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

  Six apps' test_helpers start `CapabilityStore`, but only four also start its
  authority store, so `arbor_consensus` and `arbor_orchestrator` carry the same
  latent gap. That divergence is the defect this prevents; the gateway
  breakage was just what made it visible.

  ## Why this lives in `lib/` (not `test/support`)

  Umbrella apps don't share each other's `test/support` paths, and at least six
  apps need this. It is only operational in a test build; release and
  activation-only builds return `:skipped` without starting applications or
  repopulating deliberately omitted stores.
  """

  require Logger

  @test_build Mix.env() == :test

  @doc """
  Start the security stores and supporting processes.

  Idempotent. Returns `:ok` when the work was done, or `:skipped` when
  `Arbor.Security.Supervisor` is not running — a distinguishable value rather
  than a silent no-op, so "nothing ran" cannot be mistaken for "everything is
  fine".
  """
  @spec start!(keyword()) :: :ok | :skipped
  def start!(_opts \\ []) do
    cond do
      not @test_build ->
        :skipped

      Arbor.KernelRuntime.Config.start_profile() == :activation_only ->
        :skipped

      true ->
        start_test_tree!()
    end
  end

  defp start_test_tree! do
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

    for {name, namespace, extra_opts} <- [
          {:arbor_security_capabilities, "capabilities",
           hydration_limit: Arbor.Security.Config.max_global_capabilities()},
          {:arbor_security_identities, "identities", []},
          {:arbor_security_signing_keys, "signing_keys", []},
          {:arbor_security_issuers, "issuers", []}
        ] do
      store_opts =
        [name: name, backend: backend, namespace: namespace]
        |> Keyword.merge(extra_opts)

      start_child!(Supervisor.child_spec({Arbor.Security.AuthorityStore, store_opts}, id: name))
    end

    :ok
  end

  defp ensure_children! do
    for spec <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.IssuerRegistry, []},
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
    child_spec = Supervisor.child_spec(spec, [])

    case Supervisor.start_child(Arbor.Security.Supervisor, child_spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, :already_present} -> restart_present_child!(child_spec.id)
      {:error, reason} -> raise "TestBootstrap: #{inspect(spec)} failed: #{inspect(reason)}"
    end
  end

  defp restart_present_child!(child_id) do
    case Supervisor.restart_child(Arbor.Security.Supervisor, child_id) do
      {:ok, _pid} ->
        :ok

      {:ok, _pid, _info} ->
        :ok

      {:error, :running} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        raise "TestBootstrap: restart #{inspect(child_id)} failed: #{inspect(reason)}"
    end
  end
end

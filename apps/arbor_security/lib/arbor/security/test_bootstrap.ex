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

  @supervisor Arbor.Security.Supervisor
  @restart_attempts 256

  # Forward rest_for_one startup order (capabilities first). On this OTP,
  # Supervisor.which_children/1 lists the same children in reverse, so order
  # proofs compare observed ids to Enum.reverse/1 of this list — never to the
  # forward list itself.
  @canonical_start_ids [
    :arbor_security_capabilities,
    :arbor_security_identities,
    :arbor_security_signing_keys,
    :arbor_security_issuers,
    Arbor.Security.Identity.Registry,
    Arbor.Security.IssuerRegistry,
    Arbor.Security.Identity.NonceCache,
    Arbor.Security.Identity.ReplayPeers,
    Arbor.Security.SystemAuthority,
    Arbor.Security.SigningAuthorityStateOwner,
    Arbor.Security.SigningAuthorityBroker,
    Arbor.Security.Constraint.RateLimiter,
    Arbor.Security.CapabilityStore,
    Arbor.Security.Reflex.Registry,
    Arbor.Security.DeliveryReceiptBroker
  ]

  @signing_authority_pair [
    Arbor.Security.SigningAuthorityStateOwner,
    Arbor.Security.SigningAuthorityBroker
  ]

  if Mix.env() == :test do
    @doc """
    Start the security stores and supporting processes.

    Idempotent. Returns `:ok` when the work was done, or `:skipped` when
    `Arbor.Security.Supervisor` is not running — a distinguishable value rather
    than a silent no-op, so "nothing ran" cannot be mistaken for "everything is
    fine". Success means each expected name's `whereis` pid equals the supervisor
    child pid under that id; name occupancy alone is never success.
    """
    @spec start!(keyword()) :: :ok | :skipped
    def start!(_opts \\ []) do
      if Arbor.KernelRuntime.Config.start_profile() == :activation_only do
        :skipped
      else
        start_test_tree!()
      end
    end

    @doc false
    @spec restore_supervised_tree!() :: :ok | :skipped
    def restore_supervised_tree!, do: start!()

    @doc false
    @spec canonical_start_ids() :: [atom()]
    def canonical_start_ids, do: @canonical_start_ids

    defp start_test_tree! do
      _ = Application.ensure_all_started(:arbor_security)

      if Process.whereis(@supervisor) do
        reconcile_tree!()
      else
        Logger.warning(
          "[Arbor.Security.TestBootstrap] Arbor.Security.Supervisor is not running; " <>
            "capability grants will fail with :capability_store_unavailable"
        )

        :skipped
      end
    end

    defp reconcile_tree! do
      case classify_tree() do
        :ok -> :ok
        :restart_terminated -> restart_terminated_children!()
        :rebuild -> rebuild_canonical_tree!()
      end
    end

    defp classify_tree do
      entries = child_entries()
      observed = Enum.map(entries, &elem(&1, 0))
      expected = @canonical_start_ids
      reverse = Enum.reverse(expected)

      cond do
        foreign_occupancy?(entries) ->
          :rebuild

        observed == reverse and Enum.all?(expected, &owned?(entries, &1)) ->
          :ok

        observed == reverse and MapSet.new(observed) == MapSet.new(expected) and
            only_terminated_present?(entries) ->
          :restart_terminated

        true ->
          :rebuild
      end
    end

    defp foreign_occupancy?(entries) do
      Enum.any?(@canonical_start_ids, fn id ->
        case Process.whereis(id) do
          pid when is_pid(pid) ->
            case child_pid_for(entries, id) do
              ^pid -> not Process.alive?(pid)
              _other -> true
            end

          nil ->
            false
        end
      end)
    end

    defp only_terminated_present?(entries) do
      Enum.all?(@canonical_start_ids, fn id ->
        case child_pid_for(entries, id) do
          pid when is_pid(pid) -> owned?(entries, id)
          :undefined -> is_nil(Process.whereis(id))
          :missing -> false
        end
      end) and
        Enum.any?(@canonical_start_ids, fn id -> child_pid_for(entries, id) == :undefined end)
    end

    defp restart_terminated_children! do
      entries = child_entries()
      pair_down? = Enum.any?(@signing_authority_pair, &(child_pid_for(entries, &1) == :undefined))

      Enum.each(@canonical_start_ids, fn id ->
        cond do
          id in @signing_authority_pair and pair_down? ->
            restart_present_child!(id)

          child_pid_for(entries, id) == :undefined ->
            restart_present_child!(id)

          true ->
            :ok
        end
      end)

      prove_owned_and_ordered!()
    end

    defp rebuild_canonical_tree! do
      stop_foreign_named_processes!()
      stop_security_application()
      previous = Application.fetch_env(:arbor_security, :start_children)
      Application.put_env(:arbor_security, :start_children, false)

      try do
        {:ok, _} = Application.ensure_all_started(:arbor_security)
      after
        restore_start_children(previous)
      end

      start_canonical_children!()
      prove_owned_and_ordered!()
    end

    defp restore_start_children({:ok, value}),
      do: Application.put_env(:arbor_security, :start_children, value)

    defp restore_start_children(:error), do: Application.delete_env(:arbor_security, :start_children)

    defp stop_security_application do
      try do
        _ = Application.stop(:arbor_security)
        :ok
      catch
        :exit, {:noproc, _} -> :ok
        :exit, :noproc -> :ok
      end
    end

    defp start_canonical_children! do
      token = make_ref()

      Enum.each(canonical_child_specs(token), fn spec ->
        case Supervisor.start_child(@supervisor, spec) do
          {:ok, _pid} ->
            prove_owned!(spec.id)

          {:ok, _pid, _info} ->
            prove_owned!(spec.id)

          {:error, {:already_started, pid}} ->
            raise "TestBootstrap: #{inspect(spec.id)} name occupied by #{inspect(pid)} " <>
                    "which is not a supervisor child"

          {:error, reason} ->
            raise "TestBootstrap: start #{inspect(spec.id)} failed: #{inspect(reason)}"
        end
      end)
    end

    defp canonical_child_specs(token) do
      backend =
        Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

      store_specs =
        for {name, namespace, extra_opts} <- [
              {:arbor_security_capabilities, "capabilities",
               [hydration_limit: Arbor.Security.Config.max_global_capabilities()]},
              {:arbor_security_identities, "identities", []},
              {:arbor_security_signing_keys, "signing_keys", []},
              {:arbor_security_issuers, "issuers", []}
            ] do
          store_opts =
            [name: name, backend: backend, namespace: namespace]
            |> Keyword.merge(extra_opts)

          Supervisor.child_spec({Arbor.Security.AuthorityStore, store_opts}, id: name)
        end

      core_specs =
        [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.IssuerRegistry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.Identity.ReplayPeers, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.SigningAuthorityStateOwner, broker_token: token},
          {Arbor.Security.SigningAuthorityBroker, state_owner_token: token},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []},
          {Arbor.Security.DeliveryReceiptBroker, []}
        ]
        |> Enum.map(&Supervisor.child_spec(&1, []))

      store_specs ++ core_specs
    end

    defp restart_present_child!(child_id, attempt \\ 0)

    defp restart_present_child!(child_id, attempt) when attempt >= @restart_attempts do
      raise "TestBootstrap: restart #{inspect(child_id)} still :restarting"
    end

    defp restart_present_child!(child_id, attempt) do
      case restart_child_result(child_id) do
        {:ok, _pid} ->
          prove_owned!(child_id)

        {:ok, _pid, _info} ->
          prove_owned!(child_id)

        {:error, :running} ->
          prove_owned!(child_id)

        {:error, :restarting} ->
          receive do
          after
            0 -> :ok
          end

          case child_pid_for(child_entries(), child_id) do
            pid when is_pid(pid) -> prove_owned!(child_id)
            :undefined -> restart_present_child!(child_id, attempt + 1)
            :missing -> raise "TestBootstrap: restart #{inspect(child_id)} spec missing"
          end

        {:error, reason} ->
          raise "TestBootstrap: restart #{inspect(child_id)} failed: #{inspect(reason)}"
      end
    end

    defp restart_child_result(child_id) do
      Supervisor.restart_child(@supervisor, child_id)
    catch
      :exit, {:noproc, _} -> {:error, :noproc}
      :exit, :noproc -> {:error, :noproc}
    end

    defp stop_foreign_named_processes! do
      entries = child_entries()

      Enum.each(@canonical_start_ids, fn id ->
        case Process.whereis(id) do
          pid when is_pid(pid) ->
            case child_pid_for(entries, id) do
              ^pid ->
                :ok

              _other ->
                stop_foreign_pid(pid)
            end

          nil ->
            :ok
        end
      end)
    end

    defp stop_foreign_pid(pid) do
      try do
        GenServer.stop(pid)
        :ok
      catch
        :exit, {:noproc, _} -> :ok
        :exit, :noproc -> :ok
        :exit, {:normal, _} -> :ok
      end
    end

    defp prove_owned_and_ordered! do
      entries = child_entries()
      observed = Enum.map(entries, &elem(&1, 0))
      reverse = Enum.reverse(@canonical_start_ids)

      unless observed == reverse do
        raise "TestBootstrap: child listing #{inspect(observed)} != reverse canonical #{inspect(reverse)}"
      end

      Enum.each(@canonical_start_ids, &prove_owned!(&1, entries))
      :ok
    end

    defp prove_owned!(id, entries \\ nil) do
      entries = entries || child_entries()

      unless owned?(entries, id) do
        raise "TestBootstrap: #{inspect(id)} is not supervisor-owned " <>
                "(child=#{inspect(child_pid_for(entries, id))} whereis=#{inspect(Process.whereis(id))})"
      end

      :ok
    end

    defp owned?(entries, id) do
      case child_pid_for(entries, id) do
        pid when is_pid(pid) -> Process.alive?(pid) and Process.whereis(id) == pid
        _other -> false
      end
    end

    defp child_pid_for(entries, id) do
      case List.keyfind(entries, id, 0) do
        {^id, pid, _type, _modules} -> pid
        nil -> :missing
      end
    end

    defp child_entries do
      case Process.whereis(@supervisor) do
        pid when is_pid(pid) ->
          try do
            Supervisor.which_children(@supervisor)
          catch
            :exit, {:noproc, _} -> []
            :exit, :noproc -> []
          end

        nil ->
          []
      end
    end
  else
    @doc """
    Start the security stores and supporting processes.

    Non-test builds return `:skipped` without starting applications or
    repopulating deliberately omitted stores.
    """
    @spec start!(keyword()) :: :ok | :skipped
    def start!(_opts \\ []), do: :skipped
  end
end

defmodule Arbor.Scheduler.Identity do
  @moduledoc """
  Per-machine cryptographic identity for the scheduler.

  The scheduler owns a reload-stable `Arbor.Contracts.Security.SigningAuthority`
  for the lifetime of this GenServer. Private key material is used only during
  startup to prove possession and open that authority; the GenServer state
  retains only the principal id and opaque authority reference.

  The authority key is indexed by the same derived `agent_id` used by the
  identity registry and the authority proof. The scheduler display name is the
  normal durable locator. `system_scheduler` is read only as a fallback for
  legacy installations and is never created for a fresh identity.
  """

  use GenServer

  require Logger

  alias Arbor.Contracts.Security.Identity, as: IdentityStruct
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Security
  alias Arbor.Trust

  @identity_name "scheduler"
  @legacy_signing_locator "system_scheduler"
  @blanket_capability "arbor://orchestrator/execute/**"
  @trust_rule_prefix "arbor://orchestrator/execute"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the stable scheduler principal id, or `nil` when not running."
  @spec agent_id() :: String.t() | nil
  def agent_id do
    case GenServer.call(__MODULE__, :get_agent_id, 5_000) do
      {:ok, id} -> id
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc "Returns the opaque authority owned by the scheduler Identity process."
  @spec signing_authority() :: SigningAuthority.t() | nil
  def signing_authority do
    case GenServer.call(__MODULE__, :get_signing_authority, 5_000) do
      {:ok, authority} -> authority
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  @impl true
  def init(opts) do
    security = Keyword.get(opts, :security_facade, Security)
    trust = Keyword.get(opts, :trust_facade, Trust)

    case load_or_create_identity(security) do
      {:ok, identity, status, identity_effects} ->
        case provision_runtime_authority(identity, security, trust) do
          {:ok, authority} ->
            Logger.info("[Scheduler.Identity] #{status} keypair for #{identity.agent_id}")

            {:ok,
             %{
               agent_id: identity.agent_id,
               signing_authority: authority,
               security_facade: security
             }}

          {:error, reason} ->
            rollback_identity(identity, identity_effects, security)
            Logger.error("[Scheduler.Identity] init failed: #{inspect(reason)}")
            {:stop, reason}
        end

      {:error, reason} ->
        Logger.error("[Scheduler.Identity] init failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_signing_authority, _from, state) do
    {:reply, {:ok, state.signing_authority}, state}
  end

  def handle_call(:get_agent_id, _from, state) do
    {:reply, {:ok, state.agent_id}, state}
  end

  @impl true
  def terminate(_reason, %{signing_authority: authority, security_facade: security}) do
    _ = security.close_signing_authority(authority)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp load_or_create_identity(security) do
    case find_named_identity(security) do
      {:ok, identity} ->
        {:ok, identity, :loaded, no_identity_effects()}

      :not_found ->
        load_from_legacy_locator(security)

      {:error, _} = error ->
        error
    end
  end

  defp find_named_identity(security) do
    case security.lookup_identity_ids_by_display_name(@identity_name) do
      {:ok, agent_ids} -> find_valid_named_identity(agent_ids, security)
      {:error, :not_found} -> :not_found
      {:error, reason} -> {:error, {:identity_lookup_failed, reason}}
    end
  rescue
    exception -> {:error, {:identity_lookup_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:identity_lookup_exit, reason}}
  end

  defp find_valid_named_identity(agent_ids, security) do
    result =
      Enum.find_value(agent_ids, fn agent_id ->
        with {:ok, signing_key} <- security.load_signing_key(agent_id),
             {:ok, %{agent_id: ^agent_id} = identity} <- identity_from_key(signing_key) do
          expected_public_key = identity.public_key

          case security.lookup_public_key(agent_id) do
            {:ok, ^expected_public_key} -> {:ok, identity}
            _ -> nil
          end
        else
          _ -> nil
        end
      end)

    result || {:error, :named_scheduler_key_unavailable}
  end

  defp load_from_legacy_locator(security) do
    case security.load_signing_key(@legacy_signing_locator) do
      {:ok, signing_key} -> load_legacy_identity(signing_key, security)
      {:error, :no_signing_key} -> create_new(security)
      {:error, reason} -> {:error, {:legacy_locator_read_failed, reason}}
    end
  rescue
    exception -> {:error, {:legacy_locator_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:legacy_locator_exit, reason}}
  end

  defp load_legacy_identity(signing_key, security) do
    with {:ok, identity} <- identity_from_key(signing_key) do
      case ensure_principal_key(identity, security) do
        {:ok, principal_key_created?} ->
          case ensure_registered(identity, security) do
            {:ok, identity_created?} ->
              {:ok, identity, :loaded,
               %{
                 principal_key_created?: principal_key_created?,
                 identity_created?: identity_created?
               }}

            {:error, _} = error ->
              if principal_key_created?, do: safe_delete_key(identity.agent_id, security)
              error
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp ensure_principal_key(identity, security) do
    case security.load_signing_key(identity.agent_id) do
      {:ok, existing_key} ->
        case identity_from_key(existing_key) do
          {:ok, %{agent_id: agent_id}} when agent_id == identity.agent_id -> {:ok, false}
          _ -> {:error, :principal_signing_key_mismatch}
        end

      {:error, :no_signing_key} ->
        case security.store_signing_key(identity.agent_id, identity.private_key) do
          :ok -> {:ok, true}
          {:error, reason} -> {:error, {:principal_key_store_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:principal_key_read_failed, reason}}
    end
  end

  defp ensure_registered(identity, security) do
    case security.lookup_public_key(identity.agent_id) do
      {:ok, public_key} when public_key == identity.public_key ->
        {:ok, false}

      {:ok, _other_public_key} ->
        {:error, :registered_public_key_mismatch}

      {:error, :not_found} ->
        case security.register_identity(IdentityStruct.public_only(identity)) do
          :ok -> {:ok, true}
          {:error, {:already_registered, _}} -> ensure_registered(identity, security)
          {:error, reason} -> {:error, {:identity_registration_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:identity_lookup_failed, reason}}
    end
  end

  defp create_new(security) do
    with {:ok, identity} <- security.generate_identity(name: @identity_name),
         :ok <- ensure_fresh_principal_available(identity, security),
         :ok <- security.store_signing_key(identity.agent_id, identity.private_key) do
      case safe_register_fresh_identity(identity, security) do
        :ok ->
          {:ok, identity, :generated, %{principal_key_created?: true, identity_created?: true}}

        {:error, reason} ->
          _ = security.delete_signing_key(identity.agent_id)
          {:error, {:identity_registration_failed, reason}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:identity_creation_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:identity_creation_exit, reason}}
  end

  defp safe_register_fresh_identity(identity, security) do
    security.register_identity(IdentityStruct.public_only(identity))
  rescue
    exception -> {:error, {:registration_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:registration_exit, reason}}
  end

  defp ensure_fresh_principal_available(identity, security) do
    with {:error, :no_signing_key} <- security.load_signing_key(identity.agent_id),
         {:error, :not_found} <- security.lookup_public_key(identity.agent_id) do
      :ok
    else
      {:ok, _} -> {:error, :fresh_principal_collision}
      {:error, reason} -> {:error, {:fresh_principal_preflight_failed, reason}}
    end
  end

  defp identity_from_key(signing_key) do
    {public_key, _} = :crypto.generate_key(:eddsa, :ed25519, signing_key)
    IdentityStruct.new(public_key: public_key, private_key: signing_key)
  end

  defp provision_runtime_authority(identity, security, trust) do
    case ensure_capability(identity.agent_id, security) do
      {:ok, capability_effect} ->
        case ensure_trust_profile(identity.agent_id, trust) do
          {:ok, trust_effect} ->
            case open_authority(identity, security) do
              {:ok, authority} ->
                {:ok, authority}

              {:error, reason} ->
                rollback_trust(trust_effect, identity.agent_id, trust)
                rollback_capability(capability_effect, security)
                {:error, {:signing_authority_open_failed, reason}}
            end

          {:error, reason} ->
            rollback_capability(capability_effect, security)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_capability(agent_id, security) do
    case security.list_capabilities(agent_id) do
      {:ok, capabilities} ->
        if Enum.any?(capabilities, &(&1.resource_uri == @blanket_capability)) do
          {:ok, :existing}
        else
          case security.grant(principal: agent_id, resource: @blanket_capability) do
            {:ok, capability} -> {:ok, {:created, capability.id}}
            {:error, reason} -> {:error, {:capability_provision_failed, reason}}
          end
        end

      {:error, reason} ->
        {:error, {:capability_lookup_failed, reason}}
    end
  rescue
    exception -> {:error, {:capability_provision_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:capability_provision_exit, reason}}
  end

  defp ensure_trust_profile(agent_id, trust) do
    case trust.get_trust_profile(agent_id) do
      {:ok, profile} ->
        desired_rules = Map.put(profile.rules || %{}, @trust_rule_prefix, :allow)

        if desired_rules == profile.rules do
          {:ok, :existing}
        else
          case trust.ensure_trust_profile(agent_id,
                 baseline: profile.baseline,
                 rules: desired_rules
               ) do
            {:ok, _profile} -> {:ok, {:updated, profile}}
            {:error, reason} -> {:error, {:trust_profile_provision_failed, reason}}
          end
        end

      {:error, :not_found} ->
        case trust.ensure_trust_profile(agent_id,
               baseline: :ask,
               rules: %{@trust_rule_prefix => :allow}
             ) do
          {:ok, _profile} -> {:ok, :created}
          {:error, reason} -> {:error, {:trust_profile_provision_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:trust_profile_lookup_failed, reason}}
    end
  rescue
    exception -> {:error, {:trust_profile_provision_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:trust_profile_provision_exit, reason}}
  end

  defp open_authority(identity, security) do
    with {:ok, proof} <-
           security.build_signing_authority_acquisition_proof(
             identity.agent_id,
             identity.private_key,
             purpose: :scheduler,
             owner: self()
           ) do
      security.open_signing_authority(proof)
    end
  end

  defp rollback_capability(:existing, _security), do: :ok

  defp rollback_capability({:created, capability_id}, security) do
    _ = security.revoke(capability_id)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp rollback_trust(:existing, _agent_id, _trust), do: :ok

  defp rollback_trust(:created, agent_id, trust) do
    _ = trust.delete_trust_profile(agent_id)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp rollback_trust({:updated, profile}, agent_id, trust) do
    _ =
      trust.ensure_trust_profile(agent_id,
        baseline: profile.baseline,
        rules: profile.rules || %{}
      )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp rollback_identity(identity, effects, security) do
    if effects.identity_created?, do: safe_deregister(identity.agent_id, security)
    if effects.principal_key_created?, do: safe_delete_key(identity.agent_id, security)
    :ok
  end

  defp safe_deregister(agent_id, security) do
    _ = security.deregister_identity(agent_id)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_delete_key(agent_id, security) do
    _ = security.delete_signing_key(agent_id)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp no_identity_effects do
    %{principal_key_created?: false, identity_created?: false}
  end
end

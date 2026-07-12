defmodule Arbor.Scheduler.Identity do
  @moduledoc """
  Per-machine cryptographic identity for the scheduler.

  The scheduler owns a reload-stable `Arbor.Contracts.Security.SigningAuthority`
  for the lifetime of this GenServer. Private key material is used only during
  startup to prove possession and open that authority; the GenServer state
  retains only the principal id and opaque authority reference.

  The authority key is indexed by the same derived `agent_id` used by the
  identity registry and the authority proof. The scheduler name is the normal
  public locator, while `system_scheduler` is retained as an explicit durable
  fallback for legacy identities; neither locator is used as the authority
  principal.
  """

  use GenServer

  require Logger

  alias Arbor.Contracts.Security.Identity, as: IdentityStruct
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Security
  alias Arbor.Trust

  @identity_name "scheduler"
  @signing_locator "system_scheduler"
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
  def init(_opts) do
    with {:ok, identity, status} <- load_or_create_identity(),
         :ok <- ensure_capability(identity.agent_id),
         :ok <- ensure_trust_profile(identity.agent_id),
         {:ok, proof} <-
           Security.build_signing_authority_acquisition_proof(
             identity.agent_id,
             identity.private_key,
             purpose: :scheduler,
             owner: self()
           ),
         {:ok, authority} <- Security.open_signing_authority(proof) do
      Logger.info("[Scheduler.Identity] #{status} keypair for #{identity.agent_id}")
      {:ok, %{agent_id: identity.agent_id, signing_authority: authority}}
    else
      {:error, reason} = error ->
        Logger.error("[Scheduler.Identity] init failed: #{inspect(reason)}")
        {:stop, error}
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
  def terminate(_reason, %{signing_authority: authority}) do
    _ = Security.close_signing_authority(authority)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp load_or_create_identity do
    case find_named_identity() do
      {:ok, identity} -> {:ok, identity, :loaded}
      :not_found -> load_from_durable_locator()
    end
  end

  defp find_named_identity do
    case Security.lookup_identity_ids_by_display_name(@identity_name) do
      {:ok, agent_ids} ->
        Enum.find_value(agent_ids, :not_found, fn agent_id ->
          case Security.load_signing_key(agent_id) do
            {:ok, signing_key} ->
              case identity_from_key(signing_key) do
                {:ok, %{agent_id: ^agent_id} = identity} ->
                  with :ok <- ensure_principal_key(identity), :ok <- register(identity) do
                    {:ok, identity}
                  else
                    _ -> false
                  end

                _ ->
                  false
              end

            _ ->
              false
          end
        end)

      {:error, :not_found} ->
        :not_found

      _ ->
        :not_found
    end
  end

  defp load_from_durable_locator do
    case Security.load_signing_key(@signing_locator) do
      {:ok, signing_key} ->
        with {:ok, identity} <- identity_from_key(signing_key),
             :ok <- ensure_principal_key(identity),
             :ok <- register(identity) do
          {:ok, identity, :loaded}
        end

      _ ->
        create_new()
    end
  end

  defp ensure_principal_key(identity) do
    case Security.load_signing_key(identity.agent_id) do
      {:ok, _signing_key} ->
        :ok

      {:error, :no_signing_key} ->
        Security.store_signing_key(identity.agent_id, identity.private_key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_new do
    with {:ok, identity} <- Security.generate_identity(name: @identity_name),
         :ok <- Security.store_signing_key(identity.agent_id, identity.private_key),
         :ok <- Security.store_signing_key(@signing_locator, identity.private_key),
         :ok <- register(identity) do
      {:ok, identity, :generated}
    end
  end

  defp identity_from_key(signing_key) do
    {public_key, _} = :crypto.generate_key(:eddsa, :ed25519, signing_key)
    IdentityStruct.new(public_key: public_key, private_key: signing_key)
  end

  defp register(%IdentityStruct{} = identity) do
    case Security.register_identity(IdentityStruct.public_only(identity)) do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
      other -> other
    end
  end

  defp ensure_capability(agent_id) do
    case Security.grant(principal: agent_id, resource: @blanket_capability) do
      {:ok, _} ->
        :ok

      {:error, :already_granted} ->
        :ok

      {:error, {:already_granted, _}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Scheduler.Identity] capability grant failed for #{agent_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp ensure_trust_profile(agent_id) do
    opts =
      case Trust.get_trust_profile(agent_id) do
        {:ok, profile} ->
          [
            baseline: profile.baseline,
            rules: Map.put(profile.rules || %{}, @trust_rule_prefix, :allow)
          ]

        {:error, :not_found} ->
          [baseline: :ask, rules: %{@trust_rule_prefix => :allow}]

        {:error, reason} ->
          Logger.warning(
            "[Scheduler.Identity] could not read trust profile for #{agent_id}: #{inspect(reason)}"
          )

          [baseline: :ask, rules: %{@trust_rule_prefix => :allow}]
      end

    case Trust.ensure_trust_profile(agent_id, opts) do
      {:ok, _profile} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Scheduler.Identity] could not ensure trust profile for #{agent_id}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "[Scheduler.Identity] trust profile setup failed for #{agent_id}: #{inspect(exception)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "[Scheduler.Identity] trust profile setup exited for #{agent_id}: #{inspect(reason)}"
      )

      :ok
  end
end

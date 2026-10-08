if Mix.env() == :test do
  defmodule Arbor.Agent.LifecycleActorFixture do
    @moduledoc """
    Test-only actor authority for `Arbor.Agent.Lifecycle.create/2`.

    Since `ddf05e470`, `Lifecycle.create/2` requires `:actor_authority`: a signing
    authority owned by a registered principal that may enroll the new identity
    and grant every requested capability. Without one, creation fails closed with
    `{:error, :capability_mutation_unauthorized}`. Production callers pass the
    authenticated caller's authority. This fixture mints a throwaway actor
    holding the security-mutation rights that creation exercises:

      * `arbor://security/identity/register` — enroll the new identity
      * `arbor://security/identity/endorse/*` — endorse it
      * `arbor://security/grant/*` — grant its initial, workspace, owner-chat
        and self-memory capabilities

    The wildcard covers only the final segment, which is the agent id that does
    not exist before creation. Callers may add `:extra_resources`.

    The authority is owned by the process that calls `open/1`. Open it in the
    test process that calls `Lifecycle.create/2`, not in `setup_all`, which runs
    in a different process. Use it through `Arbor.Agent.open_lifecycle_actor_fixture/1`
    and `Arbor.Agent.close_lifecycle_actor_fixture/1`. Absent from non-test builds.
    """

    alias Arbor.Contracts.Security.Identity

    @resources [
      "arbor://security/identity/register",
      "arbor://security/identity/endorse/*",
      "arbor://security/grant/*"
    ]

    @type t :: %{
            actor_id: String.t(),
            authority: term(),
            capability_ids: [String.t()]
          }

    @doc "Register a throwaway actor, grant it creation rights and open its authority."
    @spec open(keyword()) :: {:ok, t()} | {:error, term()}
    def open(opts \\ []) when is_list(opts) do
      name = Keyword.get(opts, :name, "lifecycle-actor-#{System.unique_integer([:positive])}")
      resources = @resources ++ Keyword.get(opts, :extra_resources, [])

      with {:ok, actor} <- Identity.generate(name: name),
           :ok <- Arbor.Security.register_identity_fixture(Identity.public_only(actor)) do
        case grant_and_open(actor, resources) do
          {:ok, _fixture} = ok ->
            ok

          {:error, _reason} = error ->
            _ = Arbor.Security.revoke_all_fixture(actor.agent_id)
            _ = Arbor.Security.delete_signing_key_fixture(actor.agent_id)
            _ = Arbor.Security.deregister_identity_fixture(actor.agent_id)
            error
        end
      end
    end

    @doc """
    Close the authority and remove the actor's capabilities and identity.

    Safe from any process. If the owning test process has already exited, the
    broker has released the authority, and closing it again is a no-op.
    """
    @spec close(t()) :: :ok
    def close(%{actor_id: actor_id, authority: authority, capability_ids: capability_ids}) do
      _ = Arbor.Security.close_signing_authority(authority)
      Enum.each(capability_ids, &Arbor.Security.revoke_fixture/1)
      _ = Arbor.Security.delete_signing_key_fixture(actor_id)
      _ = Arbor.Security.deregister_identity_fixture(actor_id)
      :ok
    end

    def close(_fixture), do: :ok

    defp grant_and_open(actor, resources) do
      # The broker loads the actor's key from the signing-key store when it opens
      # the authority; the acquisition proof alone is not enough.
      with {:ok, capability_ids} <- grant_all(actor.agent_id, resources),
           :ok <- store_signing_key(actor),
           {:ok, proof} <-
             Arbor.Security.build_signing_authority_acquisition_proof(
               actor.agent_id,
               actor.private_key,
               purpose: :lifecycle_actor_fixture,
               owner: self()
             ),
           {:ok, authority} <- Arbor.Security.open_signing_authority(proof) do
        {:ok, %{actor_id: actor.agent_id, authority: authority, capability_ids: capability_ids}}
      end
    end

    defp store_signing_key(actor) do
      case Arbor.Security.store_signing_key_fixture(actor.agent_id, actor.private_key) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:actor_signing_key_failed, reason}}
      end
    end

    defp grant_all(actor_id, resources) do
      Enum.reduce_while(resources, {:ok, []}, fn resource, {:ok, ids} ->
        case Arbor.Security.grant_fixture(principal: actor_id, resource: resource) do
          {:ok, capability} -> {:cont, {:ok, [capability.id | ids]}}
          {:error, reason} -> {:halt, {:error, {:actor_grant_failed, resource, reason}}}
        end
      end)
    end
  end
end

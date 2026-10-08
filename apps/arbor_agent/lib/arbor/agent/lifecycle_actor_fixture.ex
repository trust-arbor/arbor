if Mix.env() == :test do
  defmodule Arbor.Agent.LifecycleActorFixture do
    @moduledoc """
    Test-only actor authority for `Arbor.Agent.Lifecycle.create/2` and
    `Lifecycle.destroy/2`.

    Since `ddf05e470`, both require `:actor_authority`: a signing authority owned
    by a registered principal that holds the matching security-mutation rights.
    Without one, they fail closed with
    `{:error, :capability_mutation_unauthorized}`. Production callers pass the
    authenticated caller's authority. This fixture mints a throwaway actor
    holding the rights an agent's lifecycle exercises:

      * `arbor://security/identity/register` — enroll the new identity
      * `arbor://security/identity/endorse/*` — endorse it
      * `arbor://security/grant/*` — grant its initial, workspace, owner-chat
        and self-memory capabilities
      * `arbor://security/revoke/*` — destroy and fail-closed cleanup: revoke its
        capabilities
      * `arbor://security/identity/deregister/*` — destroy: deregister it, which
        also lets its stored signing key be deleted
      * `arbor://security/identity/suspend/*` and `.../resume/*` — exact-template
        activation: suspend the identity when activation fails closed, resume it
        when activation succeeds

    Without the last two, `destroy/2` still returns `:ok` but only logs
    "destroy cleanup was incomplete", leaving the identity, capabilities and key
    behind. The wildcards cover only the final segment, which is the agent id that
    does not exist before creation. Callers may add `:extra_resources`.

    ## Audit journal budget

    Every grant and revoke is a Security audit journal operation. Test runs do
    not start the Historian puller, so no operation is ever delivered: each one
    stays pending, holding its two written entries plus one reserved for the
    delivery. Against the ephemeral `:operational` journal's 3072-entry soft
    cap, that gives each app's test run one fixed budget of about 1020
    operations. Past it, every grant in the rest of the run fails with
    `{:error, :audit_unavailable}`, in whichever modules run last. Minting an
    actor costs 7 operations and closing it 7 more; creating a `test_agent`
    costs 10 and destroying it 10. So share one actor per module:

        setup_all do
          {:ok, principal} = Arbor.Agent.open_lifecycle_actor_fixture()
          on_exit(fn -> Arbor.Agent.close_lifecycle_actor_fixture(principal) end)
          {:ok, lifecycle_principal: principal}
        end

        setup %{lifecycle_principal: principal} do
          {:ok, actor} = Arbor.Agent.reopen_lifecycle_actor_fixture(principal)
          {:ok, lifecycle_actor: actor}
        end

    An authority is owned by the process that opens it, and the broker releases
    it when that process exits. `reopen/1` opens one for the calling process
    and records no security mutation. For `on_exit` cleanup, which runs after
    the test process has exited, use `destroy_agent/2` with the shared actor.

    Use all of these through the `Arbor.Agent` facade:
    `open_lifecycle_actor_fixture/1`, `reopen_lifecycle_actor_fixture/1`,
    `close_lifecycle_actor_fixture/1` and `destroy_agent_fixture/2`. Absent
    from non-test builds.
    """

    alias Arbor.Agent.Lifecycle
    alias Arbor.Contracts.Security.Identity

    @resources [
      "arbor://security/identity/register",
      "arbor://security/identity/endorse/*",
      "arbor://security/grant/*",
      "arbor://security/revoke/*",
      "arbor://security/identity/deregister/*",
      "arbor://security/identity/suspend/*",
      "arbor://security/identity/resume/*"
    ]

    @type t :: %{
            actor_id: String.t(),
            authority: term(),
            capability_ids: [String.t()],
            private_key: binary(),
            principal_owner?: boolean()
          }

    @doc "Register a throwaway actor, grant it lifecycle rights and open its authority."
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
    Open another authority for an existing actor, owned by the calling process.

    Records no security mutation: the actor's identity and rights already exist.
    The returned handle shares the actor; closing it closes only its authority.
    """
    @spec reopen(t()) :: {:ok, t()} | {:error, term()}
    def reopen(%{actor_id: actor_id, private_key: private_key} = actor) do
      with {:ok, authority} <- open_authority(actor_id, private_key) do
        {:ok, %{actor | authority: authority, principal_owner?: false}}
      end
    end

    @doc """
    Close a handle.

    For a handle from `open/1`: close its authority and remove the actor's
    capabilities, key and identity. That revokes *every* capability the actor
    holds, including any a test added on top (e.g. a role via
    `Arbor.Security.assign_role_fixture/2`). For a handle from `reopen/1`:
    close only its authority. Safe from any process. If the owning process has
    already exited, the broker has released the authority, and closing it again
    is a no-op.
    """
    @spec close(t()) :: :ok
    def close(%{principal_owner?: false, authority: authority}) do
      _ = Arbor.Security.close_signing_authority(authority)
      :ok
    end

    def close(%{actor_id: actor_id, authority: authority}) do
      _ = Arbor.Security.close_signing_authority(authority)
      _ = Arbor.Security.revoke_all_fixture(actor_id)
      _ = Arbor.Security.delete_signing_key_fixture(actor_id)
      _ = Arbor.Security.deregister_identity_fixture(actor_id)
      :ok
    end

    def close(_fixture), do: :ok

    @doc """
    Destroy an agent from any process, e.g. an `on_exit` callback.

    Reopens `actor` in the calling process (no security mutation), runs
    `Lifecycle.destroy/2` with it, then closes that handle; the actor itself
    stays. Returns the destroy result, or the error from reopening.
    """
    @spec destroy_agent(String.t(), t()) :: :ok | {:error, term()}
    def destroy_agent(agent_id, actor) when is_binary(agent_id) do
      with {:ok, handle} <- reopen(actor) do
        try do
          Lifecycle.destroy(agent_id, actor_authority: handle.authority)
        after
          close(handle)
        end
      end
    end

    defp grant_and_open(actor, resources) do
      # The broker loads the actor's key from the signing-key store when it opens
      # the authority; the acquisition proof alone is not enough.
      with {:ok, capability_ids} <- grant_all(actor.agent_id, resources),
           :ok <- store_signing_key(actor),
           {:ok, authority} <- open_authority(actor.agent_id, actor.private_key) do
        {:ok,
         %{
           actor_id: actor.agent_id,
           authority: authority,
           capability_ids: capability_ids,
           private_key: actor.private_key,
           principal_owner?: true
         }}
      end
    end

    defp open_authority(actor_id, private_key) do
      with {:ok, proof} <-
             Arbor.Security.build_signing_authority_acquisition_proof(
               actor_id,
               private_key,
               purpose: :lifecycle_actor_fixture,
               owner: self()
             ) do
        Arbor.Security.open_signing_authority(proof)
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

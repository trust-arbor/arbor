defmodule Arbor.Agent.SignedLifecycle do
  @moduledoc false
  # Agent start and resume from a request the operator signed with its key file
  # (`mix arbor.agent start` / `resume`). The CLI runs in another OS process and
  # an authority cannot cross RPC, so the server opens one here.
  #
  # `Arbor.Security.verify_request_and_open_agent_lifecycle_authority/2` checks
  # the signature against the principal's REGISTERED key over exactly the
  # payload rebuilt from the request (`LifecycleRequestCore.payload/2`),
  # consumes its nonce, and opens an `:agent_lifecycle` authority owned by this
  # process. For the local operator, whose key the server never holds, that
  # authority is caller-held: owner-bound, able to stand as the actor of the
  # lifecycle mutations, unable to sign. It is closed after the one operation.
  #
  # The capability checks are the ordinary ones: `arbor://agent/lifecycle/create`
  # to create, `arbor://agent/lifecycle/start/<id>` to start an existing agent,
  # and every security mutation inside creation checks the principal itself.

  alias Arbor.Agent.LifecycleRequestCore, as: Core
  alias Arbor.Agent.Manager
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.TenantContext

  # Process options a server-side caller may add; never authority, and not
  # part of the signed request.
  @local_start_opts [:start_session, :start_heartbeat, :recover_session]

  @spec submit(String.t(), map() | keyword(), SignedRequest.t(), keyword()) ::
          {:ok, String.t(), pid(), :created | :resumed}
          | {:ok, String.t(), pid()}
          | {:ok, :pending_approval, String.t()}
          | {:error, term()}
  def submit(principal_id, request, signed_request, opts \\ [])

  def submit(principal_id, request, %SignedRequest{} = signed_request, opts)
      when is_binary(principal_id) and is_list(opts) do
    with {:ok, request} <- Core.new(request),
         {:ok, payload} <- Core.payload(principal_id, request),
         {:ok, authority} <- open_authority(principal_id, signed_request, payload) do
      try do
        run(request, principal_id, signed_request, authority, local_opts(opts))
      after
        _ = Arbor.Security.close_signing_authority(authority)
      end
    end
  end

  def submit(_principal_id, _request, _signed_request, _opts),
    do: {:error, :invalid_lifecycle_request}

  defp open_authority(principal_id, signed_request, payload) do
    case Arbor.Security.verify_request_and_open_agent_lifecycle_authority(
           signed_request,
           payload
         ) do
      {:ok, ^principal_id, authority} ->
        {:ok, authority}

      {:ok, _other_principal, authority} ->
        _ = Arbor.Security.close_signing_authority(authority)
        {:error, {:unauthorized, :principal_mismatch}}

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
    end
  end

  defp run(%{operation: :start} = request, principal_id, signed_request, authority, opts) do
    {:ok, provider} = Core.provider_atom(request.provider)

    model_config = %{
      id: request.model,
      provider: provider,
      runtime: :arbor,
      module: Arbor.Agent.APIAgent,
      start_opts: []
    }

    case Manager.find_existing_profile(request.display_name, request.template) do
      {:ok, agent_id} ->
        start_existing(
          principal_id,
          agent_id,
          signed_request,
          authority,
          [model_config: model_config] ++ opts
        )

      :not_found ->
        create(request, principal_id, signed_request, authority, model_config, opts)
    end
  end

  defp run(
         %{operation: :resume, agent_id: agent_id},
         principal_id,
         signed_request,
         authority,
         opts
       ) do
    case start_existing(principal_id, agent_id, signed_request, authority, opts) do
      {:ok, ^agent_id, pid, :resumed} -> {:ok, agent_id, pid}
      other -> other
    end
  end

  defp start_existing(principal_id, agent_id, signed_request, authority, opts) do
    proof = [signed_request: signed_request, actor_authority: authority]

    case Arbor.Agent.authorize_start(
           principal_id,
           agent_id,
           proof ++ [principal_id: principal_id] ++ opts
         ) do
      {:ok, ^agent_id, pid} -> {:ok, agent_id, pid, :resumed}
      other -> other
    end
  end

  defp create(request, principal_id, signed_request, authority, model_config, opts) do
    case authorize(principal_id, "arbor://agent/lifecycle/create", :create, signed_request) do
      :ok ->
        start_opts =
          [
            template: request.template,
            display_name: request.display_name,
            # Names the creator so Lifecycle grants it `arbor://chat/agent/<id>`.
            tenant_context: TenantContext.new(principal_id),
            actor_authority: authority
          ] ++ opts

        case Manager.start_agent(model_config, start_opts) do
          {:ok, agent_id, pid} -> {:ok, agent_id, pid, :created}
          {:error, reason} -> {:error, reason}
        end

      {:ok, :pending_approval, _proposal_id} = pending ->
        pending

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
    end
  end

  # The broker verified `signed_request` and consumed its nonce while opening
  # the authority; verifying again would be a replay.
  defp authorize(principal_id, resource, action, signed_request) do
    case Arbor.Security.authorize(principal_id, resource, action,
           signed_request: signed_request,
           identity_verified: true
         ) do
      {:ok, :authorized} -> :ok
      {:ok, :pending_approval, _proposal_id} = pending -> pending
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :security_unavailable}
  catch
    :exit, _ -> {:error, :security_unavailable}
  end

  defp local_opts(opts) do
    if Keyword.keyword?(opts), do: Keyword.take(opts, @local_start_opts), else: []
  end
end

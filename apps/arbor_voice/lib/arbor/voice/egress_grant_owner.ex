defmodule Arbor.Voice.EgressGrantOwner do
  @moduledoc """
  Supervised owner for voice route grants and disclosure capabilities.

  The owner opens a preprovisioned service principal for each fixed mutation.
  A live, real-Security conversation binding must match the exact xAI route.
  """

  use GenServer

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security
  alias Arbor.Voice.{ConversationAuthority, EgressAuthority, EgressGrantLedger, Redacted}

  @purpose :voice_egress_grant
  @resources ["arbor://security/grant/**", "arbor://security/revoke/**"]
  @route %{
    destination: "api.x.ai",
    provider: "xai",
    runtime: "arbor",
    model: "grok-voice-latest"
  }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  def grant_route(opts, binding), do: call({:grant_route, opts, binding})

  @doc false
  def issue_disclosure(opts, binding), do: call({:issue_disclosure, opts, binding})

  @doc false
  def revoke(capability_id), do: call({:revoke, capability_id})

  defp call(request) do
    GenServer.call(__MODULE__, request, 30_000)
  catch
    :exit, _ -> {:error, :capability_mutation_unauthorized}
  end

  if Mix.env() == :test do
    @doc false
    def install_fixture!(principal_id) when is_binary(principal_id),
      do: call({:install_fixture, principal_id})

    @doc false
    def fixture_principal,
      do: Application.get_env(:arbor_voice, :egress_grant_principal_id)
  end

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)

    case EgressGrantLedger.snapshot() do
      {:ok, minted_ids} -> {:ok, %{minted_ids: minted_ids}}
      _ -> {:stop, :egress_grant_ledger_unavailable}
    end
  end

  @impl true
  def handle_call({:grant_route, opts, binding}, _from, state) do
    result =
      with :ok <- valid_binding(binding),
           :ok <- valid_route_spec(opts, binding) do
        with_authority(fn authority ->
          Security.grant_capability_id(Keyword.put(opts, :actor_authority, authority))
        end)
      end

    reply_with_minted(result, state)
  end

  def handle_call({:issue_disclosure, opts, binding}, _from, state) do
    result =
      with :ok <- valid_binding(binding),
           :ok <- valid_disclosure_spec(opts, binding) do
        with_authority(fn authority ->
          Security.issue_disclosure_capability_id(Keyword.put(opts, :actor_authority, authority))
        end)
      end

    reply_with_minted(result, state)
  end

  def handle_call({:revoke, id}, _from, state) when is_binary(id) do
    if MapSet.member?(state.minted_ids, id) do
      result = with_authority(fn authority -> Security.revoke(id, actor_authority: authority) end)

      state =
        if result in [:ok, {:error, :not_found}, {:error, :already_revoked}] do
          _ = EgressGrantLedger.forget(id)
          %{state | minted_ids: MapSet.delete(state.minted_ids, id)}
        else
          state
        end

      {:reply, result, state}
    else
      {:reply, {:error, :capability_mutation_unauthorized}, state}
    end
  end

  if Mix.env() == :test do
    def handle_call({:install_fixture, principal}, _from, state) do
      case open_provisioned(principal) do
        {:ok, authority} ->
          _ = Security.close_signing_authority(authority)
          Application.put_env(:arbor_voice, :egress_grant_principal_id, principal)
          {:reply, :ok, state}

        error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :capability_mutation_unauthorized}, state}

  @impl true
  def handle_info(:egress_grant_ledger_restarted, state) do
    _ = EgressGrantLedger.replace_all(MapSet.to_list(state.minted_ids))
    {:noreply, state}
  end

  @impl true
  def format_status(%{state: state} = status) when is_map(state) do
    Map.put(status, :state, %{minted_count: MapSet.size(state.minted_ids)})
  end

  def format_status(status), do: status

  defp reply_with_minted({:ok, id} = result, state) when is_binary(id) do
    case EgressGrantLedger.record(id) do
      :ok ->
        {:reply, result, %{state | minted_ids: MapSet.put(state.minted_ids, id)}}

      _ ->
        _ = with_authority(fn authority -> Security.revoke(id, actor_authority: authority) end)
        {:reply, {:error, :capability_mutation_unauthorized}, state}
    end
  end

  defp reply_with_minted(result, state), do: {:reply, result, state}

  defp valid_binding(%Redacted{} = binding) do
    value = Redacted.value(binding)

    if is_map(value) and value.security_module == Security and
         value.comms == Arbor.Comms and ConversationAuthority.recheck(binding) == :ok,
       do: :ok,
       else: {:error, :capability_mutation_unauthorized}
  rescue
    _ -> {:error, :capability_mutation_unauthorized}
  end

  defp valid_binding(_), do: {:error, :capability_mutation_unauthorized}

  defp valid_route_spec(opts, binding) when is_list(opts) do
    value = Redacted.value(binding)
    session_id = Keyword.get(opts, :session_id)
    expires_at = Keyword.get(opts, :expires_at)

    if EgressAuthority.canonical_session_id?(session_id) and match?(%DateTime{}, expires_at) do
      expected = [
        principal: value.agent_id,
        resource: "arbor://voice/realtime/xai/" <> session_id,
        expires_at: expires_at,
        delegation_depth: 0,
        session_id: session_id,
        task_id: nil,
        principal_scope: value.authenticated_principal_id,
        constraints: %{
          egress: %{max_tier: :external_provider, destinations: [@route.destination]}
        }
      ]

      if opts == expected and DateTime.diff(expires_at, DateTime.utc_now(), :second) in 1..86_460,
        do: :ok,
        else: {:error, :capability_mutation_unauthorized}
    else
      {:error, :capability_mutation_unauthorized}
    end
  rescue
    _ -> {:error, :capability_mutation_unauthorized}
  end

  defp valid_route_spec(_, _), do: {:error, :capability_mutation_unauthorized}

  defp valid_disclosure_spec(opts, binding) when is_list(opts) do
    value = Redacted.value(binding)

    expected = [
      principal_id: value.agent_id,
      session_id: Keyword.get(opts, :session_id),
      task_id: Keyword.get(opts, :task_id),
      principal_scope: value.authenticated_principal_id,
      destination: @route.destination,
      provider: @route.provider,
      runtime: @route.runtime,
      model: @route.model
    ]

    if opts == expected and EgressAuthority.canonical_session_id?(expected[:session_id]) and
         is_binary(expected[:task_id]) and expected[:task_id] != "",
       do: :ok,
       else: {:error, :capability_mutation_unauthorized}
  rescue
    _ -> {:error, :capability_mutation_unauthorized}
  end

  defp valid_disclosure_spec(_, _), do: {:error, :capability_mutation_unauthorized}

  defp with_authority(operation) do
    with {:ok, authority} <-
           open_provisioned(Application.get_env(:arbor_voice, :egress_grant_principal_id)) do
      try do
        operation.(authority)
      after
        _ = Security.close_signing_authority(authority)
      end
    end
  end

  defp open_provisioned(principal) when is_binary(principal) and principal != "" do
    with {:ok, capabilities} <- Security.list_capabilities(principal),
         true <-
           Enum.all?(@resources, fn resource ->
             Enum.any?(capabilities, fn
               %Capability{resource_uri: ^resource} = cap -> Capability.valid?(cap)
               _ -> false
             end)
           end),
         {:ok, proof} <-
           Security.build_stored_signing_authority_acquisition_proof(
             principal,
             @purpose,
             self(),
             __MODULE__
           ) do
      Security.open_signing_authority(proof)
    else
      _ -> {:error, :capability_mutation_unauthorized}
    end
  end

  defp open_provisioned(_), do: {:error, :capability_mutation_unauthorized}
end

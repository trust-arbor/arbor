defmodule Arbor.Gateway.Chat.LifecycleAuthority do
  @moduledoc """
  Supervised owner for signed agent-lifecycle creates.

  The authenticated request principal selects only its own stored signing
  identity. Acquisition and the fixed create operation both run in this process,
  because Security authorities are bound to the PID that opens them. The HTTP
  signature is not an acquisition proof and is never opened as one.
  """

  use GenServer

  @purpose :gateway_agent_lifecycle

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Authorize one lifecycle create using the principal's stored signing authority.

  Missing owner, key, or proof returns `{:error, :capability_mutation_unauthorized}`.
  """
  @spec authorize_create(String.t(), String.t(), keyword()) :: term()
  def authorize_create(principal, display_name, opts)
      when is_binary(principal) and is_binary(display_name) and is_list(opts) do
    GenServer.call(__MODULE__, {:authorize_create, principal, display_name, opts}, 30_000)
  catch
    :exit, _ -> {:error, :capability_mutation_unauthorized}
  end

  def authorize_create(_principal, _display_name, _opts),
    do: {:error, :capability_mutation_unauthorized}

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)
    {:ok, nil}
  end

  @impl true
  def handle_call({:authorize_create, principal, display_name, opts}, _from, state) do
    result =
      with {:ok, proof} <-
             Arbor.Security.build_stored_signing_authority_acquisition_proof(
               principal,
               @purpose,
               self(),
               __MODULE__
             ),
           {:ok, authority} <- Arbor.Security.open_signing_authority(proof) do
        try do
          bridge_call(agent_facade(), :authorize_create, [
            principal,
            display_name,
            Keyword.put(opts, :actor_authority, authority)
          ])
        after
          _ = Arbor.Security.close_signing_authority(authority)
        end
      else
        _ -> {:error, :capability_mutation_unauthorized}
      end

    {:reply, result, state}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :capability_mutation_unauthorized}, state}
  end

  if Mix.env() == :test do
    defp agent_facade,
      do: Application.get_env(:arbor_gateway, :chat_agent_facade, Arbor.Agent)
  else
    defp agent_facade, do: Arbor.Agent
  end

  defp bridge_call(module, function, args) do
    if Code.ensure_loaded?(module) do
      {:ok, apply(module, function, args)}
    else
      {:error, :not_available}
    end
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end

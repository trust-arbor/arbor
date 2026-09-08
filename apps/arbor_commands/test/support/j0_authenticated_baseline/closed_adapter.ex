defmodule Arbor.Commands.J0AuthenticatedBaseline.ClosedAdapter do
  @moduledoc false

  # Catch-all adapter installed under every known provider name except the
  # intended capture provider. Client lookup is by adapters-map key, so this
  # module's provider/0 callback is not the routing key.

  @behaviour Arbor.LLM.ProviderAdapter

  alias Arbor.LLM.Request

  @parent_key {__MODULE__, :parent}

  def set_parent(pid) when is_pid(pid), do: :persistent_term.put(@parent_key, pid)
  def clear_parent, do: :persistent_term.erase(@parent_key)

  @impl true
  def provider, do: "closed_hermetic"

  @impl true
  def complete(%Request{} = request, _opts) do
    notify({:j0_outbound_denied, request.provider, request.model, request})
    {:error, :outbound_denied}
  end

  @impl true
  def complete_single_attempt(request, opts), do: complete(request, opts)

  @impl true
  def stream(%Request{} = request, _opts) do
    notify({:j0_outbound_denied, request.provider, request.model, request})
    {:error, :outbound_denied}
  end

  @impl true
  def embed(_texts, _model, _opts), do: {:error, :outbound_denied}

  @impl true
  def runtime_contract, do: %Arbor.Contracts.AI.RuntimeContract{}

  defp notify(message) do
    case :persistent_term.get(@parent_key, nil) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end
end

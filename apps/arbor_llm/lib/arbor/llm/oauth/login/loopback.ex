defmodule Arbor.LLM.OAuth.Login.Loopback do
  @moduledoc false

  alias Arbor.LLM.OAuth.Login
  alias Arbor.LLM.OAuth.Login.LoopbackFlowSupervisor
  alias Arbor.LLM.OAuth.Login.LoopbackOwner
  alias Arbor.LLM.OAuth.Login.LoopbackPrompt
  alias Arbor.LLM.OAuth.Login.LoopbackResolver
  alias Arbor.LLM.OAuth.Login.LoopbackSupervisor

  @ports %{port_1455: 1455, port_1457: 1457}

  @spec start(keyword()) :: {:ok, LoopbackPrompt.t()} | {:error, term()}
  def start(opts) do
    with {:ok, selector} <- Login.openai_redirect_selector(opts),
         {:ok, addresses} <- LoopbackResolver.resolve() do
      start_resolved(selector, addresses)
    end
  end

  @doc false
  @spec start_resolved(atom(), term()) :: {:ok, LoopbackPrompt.t()} | {:error, term()}
  def start_resolved(selector, addresses) do
    with {:ok, port} <- Map.fetch(@ports, selector),
         {:ok, addresses} <- LoopbackResolver.validate(addresses) do
      flow_id = make_ref()

      child =
        {LoopbackFlowSupervisor,
         flow_id: flow_id, selector: selector, port: port, addresses: addresses}

      case DynamicSupervisor.start_child(LoopbackSupervisor, child) do
        {:ok, flow_pid} ->
          take_authorize_url(flow_pid, flow_id)

        {:error, _reason} ->
          {:error, :oauth_loopback_unavailable}
      end
    else
      :error -> {:error, :invalid_redirect_uri_selector}
      {:error, reason} -> {:error, reason}
    end
  end

  defp take_authorize_url(flow_pid, flow_id) do
    case LoopbackOwner.take_authorize_url(flow_id) do
      {:ok, authorize_url} ->
        {:ok, %LoopbackPrompt{authorize_url: authorize_url}}

      {:error, _reason} ->
        terminate_flow(flow_pid)
        {:error, :oauth_loopback_unavailable}
    end
  catch
    :exit, _reason ->
      terminate_flow(flow_pid)
      {:error, :oauth_loopback_unavailable}
  end

  defp terminate_flow(flow_pid) do
    DynamicSupervisor.terminate_child(LoopbackSupervisor, flow_pid)
    :ok
  catch
    :exit, _reason -> :ok
  end
end

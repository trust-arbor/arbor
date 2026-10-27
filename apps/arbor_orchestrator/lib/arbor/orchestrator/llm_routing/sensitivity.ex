defmodule Arbor.Orchestrator.LlmRouting.Sensitivity do
  @moduledoc false

  alias Arbor.LLM.Client
  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Config
  alias Arbor.Orchestrator.LlmRouting.SensitivityAdapter
  alias Arbor.Orchestrator.Session.TurnEgress

  @scope_opt :__orchestrator_sensitivity_scope__
  @selection_key {__MODULE__, :selected_provider}

  def private_opts(opts) do
    opts
    |> Keyword.take([@scope_opt])
    |> Keyword.merge(Arbor.LLM.sensitivity_options(opts))
  end

  # Only this owning compute call is wrapped. General-purpose Client callers
  # retain their own policy; the scope crosses its private deadline worker.
  def wrap_client(client, context, opts) do
    sensitivity = Context.get(context, "__data_sensitivity__")

    if sensitivity in [nil, :public] do
      {client, Keyword.delete(opts, @scope_opt)}
    else
      scope = %{
        ref: make_ref(),
        policy: Config.sensitivity_routing_module(),
        client: client,
        sensitivity: sensitivity,
        agent_id: Context.get(context, "session.agent_id")
      }

      providers = Enum.uniq(Map.keys(client.adapters) ++ Arbor.LLM.known_providers())

      wrapped = %{
        client
        | adapters: Map.new(providers, &{&1, SensitivityAdapter}),
          middleware: [selection_middleware(scope) | client.middleware],
          stream_middleware: [selection_middleware(scope) | client.stream_middleware]
      }

      opts = Keyword.put(opts, @scope_opt, scope)

      # The mandatory Client gate runs before this wrapper invokes its inner
      # adapter, so the owning compute's floor must already be present there.
      opts =
        case Arbor.LLM.carry_sensitivity(%{sensitivity: sensitivity}, opts) do
          {:ok, carried} -> carried
          {:error, _} -> Keyword.put(opts, :sensitivity, :invalid)
        end

      {wrapped, opts}
    end
  end

  def put_route_authorizer(dispatch_opts, engine_opts) do
    case Keyword.fetch(engine_opts, @scope_opt) do
      {:ok, scope} ->
        existing = Keyword.get(dispatch_opts, :route_authorizer)

        Keyword.put(dispatch_opts, :route_authorizer, fn route ->
          with :allow <- existing_admission(existing, route),
               {:ok, scalar} <- TurnEgress.project_dispatch_route(route) do
            authorize(scope, scalar.provider, scalar.model)
          else
            {:error, :invalid_route} -> {:error, {:sensitivity_blocked, :invalid_route}}
            refusal -> refusal
          end
        end)

      :error ->
        dispatch_opts
    end
  end

  # Rerouting is permitted while constructing a candidate, never as permission
  # to send unchanged sensitive bytes to the route currently being attempted.
  def authorize(scope, provider, model) do
    decision =
      if Config.sensitivity_routing_module() == scope.policy do
        apply(scope.policy, :sensitivity_routing_decision, [
          provider_atom(provider),
          model || "",
          scope.sensitivity,
          [agent_id: scope.agent_id]
        ])
      else
        :policy_changed
      end

    decision =
      if Config.sensitivity_routing_module() == scope.policy, do: decision, else: :policy_changed

    case decision do
      %{action: :proceed} -> :allow
      %{action: :blocked} -> {:error, {:sensitivity_blocked, :destination_disallowed}}
      %{action: :rerouted} -> {:error, {:sensitivity_blocked, :route_requires_rerouting}}
      _ -> unavailable()
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def invoke(scope, operation, request, middle, opts) do
    provider = selected_provider(scope, request, operation)
    current = request.provider || scope.client.default_provider

    if current != provider do
      {:error, {:sensitivity_blocked, :provider_selection_changed}}
    else
      with :allow <- authorize(scope, provider, request.model),
           {:ok, adapter} <- Client.adapter_for(scope.client, %{request | provider: provider}),
           {:ok, opts} <-
             Arbor.LLM.carry_sensitivity([request, %{sensitivity: scope.sensitivity}], opts),
           :ok <-
             Arbor.LLM.authorize_adapter_sensitivity(
               adapter,
               provider,
               request.model,
               request,
               opts
             ) do
        arity = 2 + length(middle)

        if Code.ensure_loaded?(adapter) and function_exported?(adapter, operation, arity) do
          apply(adapter, operation, [request] ++ middle ++ [opts])
        else
          unsupported(operation, adapter)
        end
      end
    end
  end

  def pop_scope(opts), do: Keyword.pop(opts, @scope_opt)

  defp existing_admission(nil, _route), do: :allow
  defp existing_admission(callback, route) when is_function(callback, 1), do: callback.(route)
  defp existing_admission(_, _), do: {:error, {:sensitivity_blocked, :invalid_route_authorizer}}

  defp selection_middleware(scope) do
    fn request, next ->
      previous = Process.get(@selection_key, :absent)
      Process.put(@selection_key, {scope.ref, request.provider || scope.client.default_provider})

      try do
        next.(request)
      after
        if previous == :absent,
          do: Process.delete(@selection_key),
          else: Process.put(@selection_key, previous)
      end
    end
  end

  defp selected_provider(scope, request, operation) do
    case Process.get(@selection_key) do
      {ref, provider} when ref == scope.ref ->
        provider

      nil when operation in [:complete_streaming, :complete_streaming_single_attempt] ->
        request.provider || scope.client.default_provider

      _ ->
        nil
    end
  end

  defp unsupported(operation, _adapter)
       when operation in [:complete_single_attempt, :complete_streaming_single_attempt],
       do: {:error, :single_attempt_not_supported}

  defp unsupported(operation, adapter) when operation in [:stream, :complete_streaming],
    do: {:error, {:stream_not_supported, adapter}}

  defp unsupported(_, _), do: {:error, :model_adapter_unavailable}

  defp provider_atom(provider) when is_atom(provider), do: provider

  defp provider_atom(provider) when is_binary(provider) do
    String.to_existing_atom(provider)
  rescue
    ArgumentError -> :unknown
  end

  defp provider_atom(_), do: :unknown
  defp unavailable, do: {:error, {:sensitivity_blocked, :policy_unavailable}}
end

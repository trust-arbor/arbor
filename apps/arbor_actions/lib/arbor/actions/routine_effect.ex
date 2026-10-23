defmodule Arbor.Actions.RoutineEffect do
  @moduledoc false

  # Routine run identities fail closed: an effect is admitted only after
  # OwnedRoutines.check_effect approves it. Catalog actions used to call
  # that check cooperatively; a skip-check action could still use the
  # ephemeral identity's granted capabilities.

  alias Arbor.Actions.Config

  @resource_key {Arbor.Actions, :action_authorization_resource}

  @spec require_catalog_enter(String.t(), map()) :: :ok | {:error, term()}
  def require_catalog_enter(principal, context)
      when is_binary(principal) and is_map(context) do
    case Map.get(context, @resource_key) do
      resource when is_binary(resource) ->
        if catalog_action_uri?(resource) do
          require_effect(principal, context, %{principal: principal, operation: :enter})
        else
          :ok
        end

      _missing ->
        :ok
    end
  end

  def require_catalog_enter(_principal, _context), do: {:error, :invalid_routine_effect}

  @spec require_file(map(), atom(), String.t()) :: :ok | {:error, term()}
  def require_file(context, operation, path)
      when is_map(context) and is_atom(operation) and is_binary(path) do
    case Map.get(context, :agent_id) do
      principal when is_binary(principal) ->
        require_effect(principal, context, %{
          principal: principal,
          operation: operation,
          path: path
        })

      _missing ->
        :ok
    end
  end

  def require_file(_context, _operation, _path), do: :ok

  defp require_effect(principal, context, effect) do
    scheduler = Config.scheduler_module()

    case requirement(scheduler, principal) do
      {:ok, false} ->
        :ok

      {:ok, true} ->
        approve(scheduler, context, effect)

      {:error, reason} ->
        if ignore_unavailable?(scheduler, reason), do: :ok, else: {:error, reason}
    end
  end

  defp approve(scheduler, context, effect) do
    case Map.fetch(context, :routine_effect_token) do
      :error ->
        {:error, :routine_effect_token_required}

      {:ok, token} ->
        scheduler.authorize_routine_effect(token, effect)
    end
  end

  defp requirement(scheduler, principal) do
    scheduler.routine_effect_requirement(principal)
  rescue
    _ -> {:error, :routine_lease_unavailable}
  catch
    _, _ -> {:error, :routine_lease_unavailable}
  end

  defp ignore_unavailable?(Arbor.Scheduler, reason)
       when reason in [:routine_lease_unavailable, :run_lease_store_unavailable] do
    not scheduler_app_started?()
  end

  defp ignore_unavailable?(_scheduler, _reason), do: false

  defp scheduler_app_started? do
    match?({_, _, _}, List.keyfind(Application.started_applications(), :arbor_scheduler, 0))
  end

  defp catalog_action_uri?(resource) do
    resource == catalog_action_uri()
  end

  defp catalog_action_uri do
    scheduler = Config.scheduler_module()

    if function_exported?(scheduler, :catalog_action_uri, 0) do
      scheduler.catalog_action_uri()
    else
      Arbor.Scheduler.catalog_action_uri()
    end
  end
end

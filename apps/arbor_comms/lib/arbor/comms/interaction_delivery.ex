defmodule Arbor.Comms.InteractionDelivery do
  @moduledoc false

  require Logger

  alias Arbor.Comms.Config
  alias Arbor.Comms.PresenceTracker
  alias Arbor.Contracts.Comms.Interaction

  @delivery_supervisor Arbor.Comms.InteractionRegistry.DeliverySupervisor

  @type retry_reason ::
          :invalid_adapter_map
          | :no_presence
          | :send_timeout
          | :delivery_supervisor_unavailable
          | {:no_adapter, atom()}
          | {:adapter_error, term()}

  @spec configured_adapters() :: %{optional(atom()) => module()}
  def configured_adapters, do: Config.interaction_adapters()

  @spec deliver_bounded(Interaction.t(), map(), pos_integer()) ::
          :ok | {:retry, retry_reason()}
  def deliver_bounded(%Interaction{} = interaction, adapter_map, timeout_ms)
      when is_map(adapter_map) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.Supervisor.async_nolink(@delivery_supervisor, fn ->
        deliver(interaction, adapter_map)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:retry, {:adapter_error, {:delivery_task_exit, reason}}}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:retry, :send_timeout}
    end
  rescue
    _ -> {:retry, :delivery_supervisor_unavailable}
  catch
    :exit, _ -> {:retry, :delivery_supervisor_unavailable}
  end

  def deliver_bounded(%Interaction{}, _adapter_map, _timeout_ms),
    do: {:retry, :invalid_adapter_map}

  @spec deliver(Interaction.t(), map()) :: :ok | {:retry, retry_reason()}
  def deliver(%Interaction{user_id: user_id} = interaction, adapter_map)
      when is_map(adapter_map) do
    case PresenceTracker.primary_channel(user_id) do
      {:ok, channel, channel_meta} ->
        deliver_to_channel(interaction, adapter_map, channel, channel_meta)

      :no_presence ->
        Logger.info(
          "[InteractionDelivery] no active presence for user #{user_id}; " <>
            "queueing #{interaction.request_id}"
        )

        {:retry, :no_presence}
    end
  end

  def deliver(%Interaction{}, _adapter_map), do: {:retry, :invalid_adapter_map}

  defp deliver_to_channel(interaction, adapter_map, channel, channel_meta) do
    case Map.get(adapter_map, channel) do
      adapter when is_atom(adapter) and not is_nil(adapter) ->
        safe_send(adapter, channel_meta, interaction)

      _missing_or_invalid ->
        Logger.info(
          "[InteractionDelivery] no adapter for channel #{inspect(channel)}; " <>
            "queueing #{interaction.request_id}"
        )

        {:retry, {:no_adapter, channel}}
    end
  end

  defp safe_send(adapter, channel_meta, interaction) do
    case adapter.send_interaction(channel_meta, interaction) do
      :ok ->
        :ok

      {:error, reason} ->
        log_adapter_failure(interaction.request_id, adapter, reason)
        {:retry, {:adapter_error, reason}}

      other ->
        log_adapter_failure(interaction.request_id, adapter, {:invalid_result, other})
        {:retry, {:adapter_error, :invalid_result}}
    end
  rescue
    error ->
      reason = {:adapter_crash, Exception.message(error)}
      log_adapter_failure(interaction.request_id, adapter, reason)
      {:retry, {:adapter_error, reason}}
  catch
    :exit, reason ->
      failure = {:adapter_exit, reason}
      log_adapter_failure(interaction.request_id, adapter, failure)
      {:retry, {:adapter_error, failure}}

    kind, reason ->
      failure = {kind, reason}
      log_adapter_failure(interaction.request_id, adapter, failure)
      {:retry, {:adapter_error, failure}}
  end

  defp log_adapter_failure(request_id, adapter, reason) do
    Logger.warning(
      "[InteractionDelivery] adapter #{inspect(adapter)} failed for #{request_id}: " <>
        "#{inspect(reason)}; interaction remains queued"
    )
  end
end

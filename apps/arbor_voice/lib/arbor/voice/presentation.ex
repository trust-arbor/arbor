defmodule Arbor.Voice.Presentation do
  @moduledoc """
  One server-owned final-audio presenter. Initial desk qualification deliberately
  keeps fixed cues and guarded speech fallback on screen; no subprocess TTS runs.
  PCM, credentials and bindings never appear in the return value or diagnostics.
  """
  use GenServer
  alias Arbor.Voice.{ConversationAuthority, Desk, DeskCore, DeskWorker, Redacted}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def present(context, presentation),
    do: GenServer.call(__MODULE__, {:present, Redacted.new({context, presentation})}, :infinity)

  @impl true
  def init(_),
    do:
      (
        Process.flag(:sensitive, true)
        Process.flag(:trap_exit, true)
        {:ok, %{current: nil, seen: []}}
      )

  @impl true
  def handle_call({:present, %Redacted{value: {ctx, p}}}, from, %{current: nil} = state) do
    cond do
      ctx.id in state.seen ->
        :atomics.put(ctx.closed, 1, 1)
        {:reply, {:error, :invalid_presentation}, state}

      not Desk.live?(ctx.permit) ->
        :atomics.put(ctx.closed, 1, 1)
        {:reply, {:error, :cancelled}, state}

      true ->
        token = make_ref()
        caller = elem(from, 0)
        fun = fn -> present_guarded(ctx, p, caller) end
        {:ok, worker} = DeskWorker.start(self(), token, fun)

        current = %{
          token: token,
          worker: worker,
          worker_ref: Process.monitor(worker),
          caller_ref: Process.monitor(elem(from, 0)),
          from: from,
          ctx: Redacted.new(ctx),
          pending: false
        }

        {:noreply, %{state | current: current, seen: Enum.take([ctx.id | state.seen], 64)}}
    end
  end

  def handle_call({:present, %Redacted{value: {ctx, _}}}, _from, state) do
    :atomics.put(ctx.closed, 1, 1)
    {:reply, {:error, :presentation_busy}, state}
  end

  @impl true
  def handle_info(
        {:desk_work, token, %Redacted{value: result}},
        %{current: %{token: token} = c} = state
      ) do
    if result == {:error, :cleanup_pending}, do: pending(state), else: finish(state, result, c)
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{current: c} = state) when c != nil do
    if ref in [c.caller_ref, c.worker_ref] do
      if Process.alive?(c.worker), do: Process.exit(c.worker, :kill)
      pending(state)
    else
      {:noreply, state}
    end
  end

  def handle_info(:retry, %{current: %{pending: true} = c} = state) do
    ctx = Redacted.value(c.ctx)

    if safe_device_status(ctx.multimedia) == :idle,
      do: finish(state, {:error, :cancelled}, c),
      else: pending(put_in(state.current.pending, false))
  end

  def handle_info(_, state), do: {:noreply, state}

  defp present_guarded(ctx, presentation, caller) do
    # Revocation kills the precise facade caller through this link before
    # a delayed presentation-owner DOWN callback could admit new media.
    Process.link(caller)

    with true <- Desk.live?(ctx.permit),
         :ok <- ConversationAuthority.recheck(ctx.binding),
         {:ok, effect} <- DeskCore.presentation(presentation),
         true <- Desk.live?(ctx.permit) do
      render_effect(ctx, effect)
    else
      _ -> {:error, :conversation_unauthorized}
    end
  end

  defp render_effect(_ctx, :screen_only), do: {:ok, :screen_only}

  defp render_effect(ctx, audio) do
    if System.monotonic_time(:millisecond) +
         div(byte_size(audio.pcm) * 500, audio.sample_rate) >= ctx.permit.deadline do
      {:error, :timeout}
    else
      case ctx.multimedia.play_pcm(audio, device_id: ctx.output_device) do
        :ok -> {:ok, :played}
        {:error, reason} -> {:error, DeskCore.error(reason)}
      end
    end
  end

  defp pending(%{current: %{pending: true}} = state), do: {:noreply, state}

  defp pending(state) do
    Process.send_after(self(), :retry, 100)
    {:noreply, put_in(state.current.pending, true)}
  end

  defp finish(state, result, c) do
    :atomics.put(Redacted.value(c.ctx).closed, 1, 1)
    Process.demonitor(c.worker_ref, [:flush])
    Process.demonitor(c.caller_ref, [:flush])
    GenServer.reply(c.from, result)
    {:noreply, %{state | current: nil}}
  end

  defp safe_device_status(module) do
    module.device_status()
  rescue
    _ -> :cleanup_pending
  catch
    _, _ -> :cleanup_pending
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})
end

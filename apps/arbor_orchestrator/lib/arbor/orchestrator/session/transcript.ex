defmodule Arbor.Orchestrator.Session.Transcript do
  @moduledoc false

  alias Arbor.Orchestrator.Session.{Builders, Persistence, TranscriptCore}

  # This shell stages a new projection. Session rechecks the current authenticated
  # owner before adopting it; neither read failure nor denial mutates live state.
  def refresh(state, authorize) do
    engagement_id = state.current_engagement_id
    anchor = Map.get(state.transcript_sync, engagement_id)
    opts = if is_map(anchor), do: [after: anchor.cursor], else: []
    scope = Map.take(state, [:session_id, :agent_id]) |> Map.put(:engagement_id, engagement_id)

    reader =
      Map.get(
        state.adapters,
        :read_session_transcript,
        &Arbor.Persistence.read_session_transcript/4
      )

    with {:ok, snapshot} <- reader.(state.session_id, state.agent_id, engagement_id, opts),
         {:ok, snapshot} <- witness_bootstrap_boundary(snapshot, anchor, reader),
         {:ok, plan} <- TranscriptCore.reconcile(snapshot, scope, anchor, state.messages),
         :ok <- authorize.() do
      # Recheck before compactor callbacks, in addition to Session's final
      # check before adoption. Refresh only appends; maybe_compact can perform
      # model work and remains on the established admitted turn commit path.
      compactor = reconcile_compactor(state, anchor, plan)

      sync = %{
        cursor: plan.cursor,
        messages: plan.messages,
        base_messages: plan.messages,
        base_compactor: compactor,
        pending: []
      }

      {:ok,
       %{
         state
         | messages: plan.messages,
           compactor: compactor,
           transcript_sync: Map.put(state.transcript_sync, engagement_id, sync)
       }
       |> Persistence.sync_checkpoint_to_session_state()}
    else
      {:error, :private_memory_admission_unavailable} = error -> error
      _ -> {:error, :transcript_unavailable}
    end
  rescue
    _ -> {:error, :transcript_unavailable}
  catch
    _, _ -> {:error, :transcript_unavailable}
  end

  # A recent bounded bootstrap can start at the assistant half of an older
  # attested pair. Observe its one preceding row for coherence only; do not
  # expand the adopted history or misclassify the limit boundary as corruption.
  defp witness_bootstrap_boundary(
         %{entries: [first | _], truncated: true} = snapshot,
         nil,
         reader
       ) do
    if first.role == "assistant" and Map.has_key?(first.metadata, "private_memory_source") do
      ordinal = first.entry_ordinal - 1

      with {:ok, witness} <-
             reader.(snapshot.session_id, snapshot.agent_id, snapshot.engagement_id,
               after: ordinal - 1,
               through: ordinal,
               limit: 1
             ),
           true <-
             witness.session_id == snapshot.session_id and witness.agent_id == snapshot.agent_id and
               witness.engagement_id == snapshot.engagement_id and witness.head == ordinal and
               witness.cursor == ordinal and witness.has_more == false,
           [entry] <- witness.entries do
        {:ok, Map.put(snapshot, :boundary_entries, [entry])}
      else
        _ -> {:error, :transcript_unavailable}
      end
    else
      {:ok, snapshot}
    end
  end

  defp witness_bootstrap_boundary(snapshot, _, _), do: {:ok, snapshot}

  def track_commit(state, entries, pair) do
    engagement_id = state.current_engagement_id

    case Map.get(state.transcript_sync, engagement_id) do
      %{pending: []} = anchor ->
        pending = Enum.zip_with(entries, pair, &%{entry: &1, message: &2})
        anchor = %{anchor | messages: state.messages, pending: pending}
        %{state | transcript_sync: Map.put(state.transcript_sync, engagement_id, anchor)}

      _ ->
        state
    end
  end

  defp reconcile_compactor(state, _anchor, %{mode: :bootstrap, messages: messages}),
    do: Builders.init_compactor(state.compactor_spec, messages)

  defp reconcile_compactor(state, _anchor, %{mode: :keep}), do: state.compactor

  defp reconcile_compactor(state, _anchor, %{mode: :append, suffix: suffix}),
    do: append(state.compactor, suffix)

  defp reconcile_compactor(_state, anchor, %{mode: :rebase, suffix: suffix}),
    do: append(anchor.base_compactor, suffix)

  defp append(nil, _), do: nil

  defp append(compactor, messages) do
    messages
    |> Enum.reduce(compactor, &Builders.apply_compactor(&2, :append, [&1]))
  end
end

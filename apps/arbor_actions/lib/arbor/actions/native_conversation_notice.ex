defmodule Arbor.Actions.NativeConversationNotice do
  @moduledoc false
  alias Arbor.Actions.{Comms.PublishConversationNotice, TaintEnforcement}

  def execute(principal, params, context, run) when is_function(run, 1) do
    # Private native worker custody is separate from action/context labels. The
    # selected capability is retained by Security; only a nonconsumable ref enters
    # this stack. There is no generic approval proposal or params preview path.
    clean_taint = Map.take(context, [:taint, :param_taint, :taint_policy, :taint_context])

    try do
      with {:ok,
            %{principal_id: ^principal, prepared: prepared, capability: cap, resource: resource}} <-
             Arbor.Security.prepare_native_notice_publication(params, source_taints(clean_taint)),
           :ok <- Arbor.Trust.check_notice_publication_policy(cap, principal, resource),
           :ok <- TaintEnforcement.check(PublishConversationNotice, params, clean_taint),
           :ok <- Arbor.Security.activate_native_notice_publication(prepared) do
        run.(context)
      else
        {:error, :notice_approval_required} = error -> error
        {:error, _} -> {:error, :notice_publication_refused}
        _ -> {:error, :notice_publication_refused}
      end
    after
      Arbor.Security.discard_native_notice_publication()
    end
  end

  defp source_taints(context) do
    # Missing or malformed native metadata is preserved conservatively by the
    # pure lower core, never promoted to trusted/internal by a permissive gate.
    aggregate = Map.get(context, :taint) || get_in(context, [:taint_context, :taint])
    params = Map.get(context, :param_taint) || get_in(context, [:taint_context, :param_taint])

    if is_map(params) and map_size(params) > 0,
      do: [aggregate | Map.values(params)],
      else: [aggregate]
  end
end

defmodule Arbor.Comms.RouterSignalApprovalSenderSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Comms.Router

  # 2026-10-11 cross-library review F-003: Signal interaction replies were
  # routed BEFORE the chat sender allowlist, and the partial path resolved the
  # configured operator's sole pending approval for whoever sent "ok"/"yes".
  # Any Signal account that could message the bot number could therefore
  # answer a pending shell / hot_load / trust escalation.
  setup do
    prev_signal = Application.get_env(:arbor_comms, :signal)
    prev_handler = Application.get_env(:arbor_comms, :handler)

    on_exit(fn ->
      restore(:signal, prev_signal)
      restore(:handler, prev_handler)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_comms, key)
  defp restore(key, value), do: Application.put_env(:arbor_comms, key, value)

  test "security regression (F-003): with no recipient or allowlist configured nobody may answer" do
    Application.put_env(:arbor_comms, :signal, [])
    Application.put_env(:arbor_comms, :handler, [])

    refute Router.interaction_sender_authorized?("+15550000000")
    refute Router.interaction_sender_authorized?("")
    refute Router.interaction_sender_authorized?(nil)
  end

  test "security regression (F-003): only the configured interaction recipient may answer" do
    Application.put_env(:arbor_comms, :signal, interaction_recipient: "+15551234567")
    Application.put_env(:arbor_comms, :handler, [])

    assert Router.interaction_sender_authorized?("+15551234567")
    refute Router.interaction_sender_authorized?("+15550000000")
  end

  test "an explicitly authorized chat sender may also answer" do
    Application.put_env(:arbor_comms, :signal, [])
    Application.put_env(:arbor_comms, :handler, authorized_senders: ["+15559999999"])

    assert Router.interaction_sender_authorized?("+15559999999")
    refute Router.interaction_sender_authorized?("+15550000000")
  end
end

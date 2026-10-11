defmodule Arbor.Actions.CommsAttachmentSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Actions.Comms.SendMessage

  # 2026-10-11 cross-library review F-010: attachment paths were read verbatim
  # (`File.read!` / `--attachment=`), so a model could mail `~/.arbor/oauth/*`
  # to any recipient once `arbor://comms/send` was allowed.
  setup do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    :ok
  end

  test "security regression (F-010): attachments without a bound principal are refused" do
    assert {:error, :attachments_require_principal} =
             SendMessage.run(
               %{channel: :email, to: "x@example.com", message: "m", attachments: ["/etc/hosts"]},
               %{}
             )
  end

  test "security regression (F-010): attachments outside the principal's fs capability are refused" do
    assert {:error, {:attachment_unauthorized, "/etc/hosts"}} =
             SendMessage.run(
               %{channel: :email, to: "x@example.com", message: "m", attachments: ["/etc/hosts"]},
               %{agent_id: "agent_no_fs_caps_#{System.unique_integer([:positive])}"}
             )
  end

  test "the recipient is the egress destination" do
    assert SendMessage.egress_destination(%{to: "x@example.com"}, %{}) == "x@example.com"
    assert is_nil(SendMessage.egress_destination(%{}, %{}))
  end
end

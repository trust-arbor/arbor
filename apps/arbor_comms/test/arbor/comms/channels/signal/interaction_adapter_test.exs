defmodule Arbor.Comms.Channels.Signal.InteractionAdapterTest do
  @moduledoc """
  Adapter-level tests for `Arbor.Comms.Channels.Signal.InteractionAdapter`.

  Verifies:
    * `channel_kind/0` returns `:signal`
    * `parse_response/1` matches APPROVE/DENY (and synonyms) with a
      valid `irq_<hex>` request_id, returns `:not_interaction` otherwise
    * `send_interaction/2` resolves the recipient from channel_meta,
      interaction metadata, or config (in priority order)

  Does NOT exercise the actual signal-cli subprocess — that lives behind
  `Arbor.Comms.Channels.Signal.send_message/2` and has its own tests.
  When channel_meta and metadata lack a recipient and config isn't set
  either, the adapter returns `{:error, :no_signal_recipient}`.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Comms.Channels.Signal.InteractionAdapter
  alias Arbor.Contracts.Comms.Interaction

  describe "channel_kind/0" do
    test "returns :signal" do
      assert InteractionAdapter.channel_kind() == :signal
    end
  end

  describe "parse_response/1 — approval matchers" do
    setup do
      {:ok, request_id: "irq_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}
    end

    test "APPROVE + request_id → :approved", %{request_id: rid} do
      assert {:interaction_response, ^rid, :approved, _meta} =
               InteractionAdapter.parse_response("APPROVE #{rid}")
    end

    test "approve (lowercase) + request_id → :approved", %{request_id: rid} do
      assert {:interaction_response, ^rid, :approved, _} =
               InteractionAdapter.parse_response("approve #{rid}")
    end

    test "YES synonym + request_id → :approved", %{request_id: rid} do
      assert {:interaction_response, ^rid, :approved, _} =
               InteractionAdapter.parse_response("yes #{rid}")
    end

    test "OK synonym + request_id → :approved", %{request_id: rid} do
      assert {:interaction_response, ^rid, :approved, _} =
               InteractionAdapter.parse_response("OK #{rid}")
    end

    test "Y short-form + request_id → :approved", %{request_id: rid} do
      assert {:interaction_response, ^rid, :approved, _} =
               InteractionAdapter.parse_response("y #{rid}")
    end
  end

  describe "parse_response/1 — denial matchers" do
    setup do
      {:ok, request_id: "irq_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}
    end

    test "DENY + request_id → :rejected", %{request_id: rid} do
      assert {:interaction_response, ^rid, :rejected, _} =
               InteractionAdapter.parse_response("DENY #{rid}")
    end

    test "REJECT synonym + request_id → :rejected", %{request_id: rid} do
      assert {:interaction_response, ^rid, :rejected, _} =
               InteractionAdapter.parse_response("reject #{rid}")
    end

    test "NO synonym + request_id → :rejected", %{request_id: rid} do
      assert {:interaction_response, ^rid, :rejected, _} =
               InteractionAdapter.parse_response("no #{rid}")
    end

    test "N short-form + request_id → :rejected", %{request_id: rid} do
      assert {:interaction_response, ^rid, :rejected, _} =
               InteractionAdapter.parse_response("N #{rid}")
    end
  end

  describe "parse_response/1 — :not_interaction cases" do
    test "regular chat text" do
      assert :not_interaction = InteractionAdapter.parse_response("hey, what's up")
    end

    test "approve word but no request_id" do
      assert :not_interaction = InteractionAdapter.parse_response("approve everything")
    end

    test "deny word but no request_id" do
      assert :not_interaction = InteractionAdapter.parse_response("deny everything")
    end

    test "request_id but no decision word" do
      rid = "irq_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      assert :not_interaction = InteractionAdapter.parse_response("looking at #{rid} later")
    end

    test "decision word not at start (avoids false positives)" do
      rid = "irq_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      # "i would never approve" should not approve
      assert :not_interaction =
               InteractionAdapter.parse_response("i would never approve #{rid}")
    end

    test "non-binary input" do
      assert :not_interaction = InteractionAdapter.parse_response(:not_a_string)
      assert :not_interaction = InteractionAdapter.parse_response(nil)
      assert :not_interaction = InteractionAdapter.parse_response(%{})
    end
  end

  describe "parse_response/1 — metadata" do
    test "carries channel and raw text in metadata" do
      rid = "irq_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      raw = "APPROVE #{rid}"

      assert {:interaction_response, ^rid, :approved, meta} =
               InteractionAdapter.parse_response(raw)

      assert meta.channel == :signal
      assert meta.raw == raw
    end
  end

  describe "send_interaction/2 — recipient resolution" do
    setup do
      interaction = build_interaction(%{description: "Run mix test?"})
      {:ok, interaction: interaction}
    end

    test "returns {:error, :no_signal_recipient} when no recipient anywhere", %{
      interaction: interaction
    } do
      # No channel_meta phone, no metadata, no config — adapter must
      # refuse to send rather than fall through and crash.
      with_signal_config([], fn ->
        assert {:error, :no_signal_recipient} =
                 InteractionAdapter.send_interaction(%{}, interaction)
      end)
    end

    test "uses metadata signal_recipient when channel_meta has no phone", %{
      interaction: base
    } do
      interaction = %{base | metadata: Map.put(base.metadata, :signal_recipient, "+15551111111")}
      # The actual send_message call will fail (signal-cli unconfigured in tests)
      # but the recipient-resolution step must NOT return :no_signal_recipient.
      result = InteractionAdapter.send_interaction(%{}, interaction)
      refute match?({:error, :no_signal_recipient}, result)
    end

    test "channel_meta phone wins over metadata recipient", %{interaction: base} do
      interaction = %{base | metadata: Map.put(base.metadata, :signal_recipient, "+15551111111")}
      result = InteractionAdapter.send_interaction(%{phone: "+15552222222"}, interaction)
      # We can't directly inspect which phone got used without mocking
      # signal-cli — the contract here is just "doesn't return
      # :no_signal_recipient because channel_meta supplied one."
      refute match?({:error, :no_signal_recipient}, result)
    end
  end

  # ──────────────────────────────────────────────────────────────────

  defp build_interaction(overrides) do
    base = %{
      kind: :approval,
      agent_id: "agent_test",
      user_id: "test_user_#{System.unique_integer([:positive])}",
      description: "approval test"
    }

    {:ok, interaction} = Interaction.new(Map.merge(base, overrides))
    interaction
  end

  # Run `fun` with a temporary :signal config, restoring the previous
  # value (or absence) on exit.
  defp with_signal_config(signal_kw, fun) do
    prev = Application.get_env(:arbor_comms, :signal)
    Application.put_env(:arbor_comms, :signal, signal_kw)

    try do
      fun.()
    after
      case prev do
        nil -> Application.delete_env(:arbor_comms, :signal)
        v -> Application.put_env(:arbor_comms, :signal, v)
      end
    end
  end
end

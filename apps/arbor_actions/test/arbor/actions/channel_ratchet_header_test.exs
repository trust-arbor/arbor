defmodule Arbor.Actions.ChannelRatchetHeaderTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Actions.Channel.Read

  describe "decode_ratchet_header/1 (M9 regression)" do
    test "round-trips a well-formed header" do
      # Sanity check: a properly-shaped header decodes back to the same map.
      valid = %{dh_public: :crypto.strong_rand_bytes(32), n: 5, pn: 3}
      bin = :erlang.term_to_binary(valid)

      assert ^valid = Read.decode_ratchet_header(bin)
    end

    test "security regression (M9): rejects a map missing required keys" do
      # M9: binary_to_term [:safe] blocks atom-table exhaustion but allows
      # arbitrary lists, maps, and tuples of existing atoms. Before the fix
      # the decoded term reached Arbor.Security.DoubleRatchet code with no
      # shape check — a malformed map would crash deep in ratchet processing
      # with a confusing error (or worse, leak data via the crash report).
      malformed = %{dh_public: <<1, 2, 3>>}
      bin = :erlang.term_to_binary(malformed)

      assert_raise ArgumentError, ~r/Invalid ratchet header shape \(M9\)/, fn ->
        Read.decode_ratchet_header(bin)
      end
    end

    test "security regression (M9): rejects negative n" do
      malformed = %{dh_public: <<1, 2, 3>>, n: -1, pn: 0}
      bin = :erlang.term_to_binary(malformed)

      assert_raise ArgumentError, ~r/Invalid ratchet header shape \(M9\)/, fn ->
        Read.decode_ratchet_header(bin)
      end
    end

    test "security regression (M9): rejects non-binary dh_public" do
      malformed = %{dh_public: :not_a_binary, n: 0, pn: 0}
      bin = :erlang.term_to_binary(malformed)

      assert_raise ArgumentError, ~r/Invalid ratchet header shape \(M9\)/, fn ->
        Read.decode_ratchet_header(bin)
      end
    end

    test "security regression (M9): rejects a list payload" do
      # The structural attack surface isn't limited to maps — a list, tuple,
      # or other [:safe]-permitted term could be crafted to confuse downstream
      # parsing.
      bin = :erlang.term_to_binary([1, 2, 3])

      assert_raise ArgumentError, ~r/Invalid ratchet header shape \(M9\)/, fn ->
        Read.decode_ratchet_header(bin)
      end
    end
  end
end

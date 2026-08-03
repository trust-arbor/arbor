defmodule Arbor.Voice.Session.ToolTaskCoreTest do
  @moduledoc "Pure tool outcome normalization and fence proofs (VP-04E3 / VOICE-8)."
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Voice.Session.JsonTerm
  alias Arbor.Voice.Session.ToolTaskCore
  alias Arbor.Voice.Session.TurnCore

  describe "authorize_progress/5" do
    @tag spec: "VOICE-11"
    test "emits only for matching generation, token, and unemitted pending" do
      token = make_ref()
      entry = %{token: token, progress_emitted: false}

      assert :emit = ToolTaskCore.authorize_progress(entry, 1, "c1", token, 1)
      assert :ignore = ToolTaskCore.authorize_progress(entry, 2, "c1", token, 1)
      assert :ignore = ToolTaskCore.authorize_progress(entry, 1, "c1", make_ref(), 1)

      assert :ignore =
               ToolTaskCore.authorize_progress(%{entry | progress_emitted: true}, 1, "c1", token, 1)

      assert :ignore = ToolTaskCore.authorize_progress(nil, 1, "c1", token, 1)
    end
  end

  describe "normalize/1" do
    @tag spec: "VOICE-8"
    test "maps success, known codes, and failure classes to bounded JSON objects" do
      assert ToolTaskCore.normalize({:error, :no_tools_installed}) ==
               TurnCore.no_tools_installed_output()

      assert Jason.decode!(ToolTaskCore.normalize({:error, :unknown_tool})) ==
               %{"code" => "unknown_tool"}

      assert Jason.decode!(ToolTaskCore.normalize({:error, :whatever})) ==
               %{"code" => "tool_error"}

      assert Jason.decode!(ToolTaskCore.normalize({:ok, %{"a" => 1}})) ==
               %{"success" => true, "result" => %{"a" => 1}}

      assert Jason.decode!(ToolTaskCore.normalize(:not_a_tuple)) ==
               %{"code" => "invalid_return"}

      assert Jason.decode!(ToolTaskCore.normalize(:tool_timeout)) ==
               %{"code" => "tool_timeout"}

      assert Jason.decode!(ToolTaskCore.normalize(:tool_failed)) ==
               %{"code" => "tool_failed"}

      assert Jason.decode!(ToolTaskCore.normalize(:tool_capacity_exceeded)) ==
               %{"code" => "tool_capacity_exceeded"}

      assert Jason.decode!(ToolTaskCore.normalize(:router_unavailable)) ==
               %{"code" => "router_unavailable"}

      assert Jason.decode!(ToolTaskCore.normalize(:tool_cancelled)) ==
               %{"code" => "tool_cancelled"}
    end

    @tag spec: "VOICE-8"
    test "security regression: rejects non-JSON terms and every configured bound" do
      assert Jason.decode!(ToolTaskCore.normalize({:ok, self()})) ==
               %{"code" => "invalid_output"}

      assert Jason.decode!(ToolTaskCore.normalize({:ok, %URI{}})) ==
               %{"code" => "invalid_output"}

      # Arbitrary atoms are not JSON terms.
      assert Jason.decode!(ToolTaskCore.normalize({:ok, :atom_result})) ==
               %{"code" => "invalid_output"}

      # Atom map keys rejected.
      assert Jason.decode!(ToolTaskCore.normalize({:ok, %{a: 1}})) ==
               %{"code" => "invalid_output"}

      deep =
        Enum.reduce(1..(JsonTerm.max_depth() + 2), 1, fn _, acc ->
          %{"n" => acc}
        end)

      assert Jason.decode!(ToolTaskCore.normalize({:ok, deep})) ==
               %{"code" => "invalid_output"}

      broad = Enum.map(1..(JsonTerm.max_nodes() + 10), fn i -> i end)

      assert Jason.decode!(ToolTaskCore.normalize({:ok, broad})) ==
               %{"code" => "invalid_output"}

      bad_utf8 = <<0xFF, 0xFE>>

      assert Jason.decode!(ToolTaskCore.normalize({:ok, bad_utf8})) ==
               %{"code" => "invalid_output"}

      improper = [1 | 2]

      assert Jason.decode!(ToolTaskCore.normalize({:ok, improper})) ==
               %{"code" => "invalid_output"}

      huge = String.duplicate("x", JsonTerm.max_encoded_bytes() + 1)

      assert Jason.decode!(ToolTaskCore.normalize({:ok, huge})) ==
               %{"code" => "invalid_output"}

      assert Jason.decode!(ToolTaskCore.normalize({:ok, %{huge => 1}})) ==
               %{"code" => "invalid_output"}
    end

    @tag spec: "VOICE-8"
    test "security regression: node ceiling accepts exactly the limit and rejects one over" do
      at_limit = List.duplicate(0, JsonTerm.max_nodes() - 1)
      over_limit = [0 | at_limit]

      assert :ok = JsonTerm.validate(at_limit)
      assert :error = JsonTerm.validate(over_limit)
    end
  end

  describe "authorize/5" do
    @tag spec: "VOICE-8"
    test "settles only on matching generation and opaque token" do
      token = make_ref()
      entry = %{token: token, owner_mon: make_ref()}

      assert :settle = ToolTaskCore.authorize(entry, 1, "c1", token, 1)
      assert :ignore = ToolTaskCore.authorize(entry, 1, "c1", token, 2)
      assert :ignore = ToolTaskCore.authorize(entry, 1, "c1", make_ref(), 1)
      assert :ignore = ToolTaskCore.authorize(nil, 1, "c1", token, 1)
      assert :ignore = ToolTaskCore.authorize(entry, 2, "c1", token, 1)
    end

    @tag spec: "VOICE-8"
    test "authorize_down matches owner monitor only" do
      mon = make_ref()
      entry = %{token: make_ref(), owner_mon: mon}

      assert :settle = ToolTaskCore.authorize_down(entry, mon, 3, 3)
      assert :ignore = ToolTaskCore.authorize_down(entry, make_ref(), 3, 3)
      assert :ignore = ToolTaskCore.authorize_down(entry, mon, 3, 4)
    end
  end
end

defmodule ArborBreeze.DraftsHintsTest do
  use ExUnit.Case, async: true
  alias ArborBreeze.{Drafts, Hints}

  test "independent unsubmitted Unicode drafts belong to exact principal Gateway and target and clear together" do
    a = {"https://gateway.test", "human_a", "agent_a"}
    b = {"https://gateway.test", "human_a", "agent_b"}
    cache = Drafts.new(2) |> Drafts.put(a, "  東京\nA  ") |> Drafts.put(b, "B")
    assert Drafts.get(cache, a) == "  東京\nA  "
    assert Drafts.get(cache, b) == "B"
    assert Drafts.get(cache, {"https://gateway.test", "human_other", "agent_a"}) == ""
    assert Drafts.get(cache, {"https://other.test", "human_a", "agent_a"}) == ""
    assert Drafts.put(cache, a, <<255>>) == cache
    assert Drafts.put(cache, a, String.duplicate("x", 32_769)) == cache
    cache = Drafts.put(cache, {"https://gateway.test", "human_a", "agent_c"}, "C")
    assert Drafts.get(cache, a) == ""
    assert Drafts.clear(cache).values == %{}
  end

  test "a hint cannot select credentials or a new Gateway and malformed state is ignored" do
    root =
      Path.join(
        System.tmp_dir!(),
        "breeze-hints-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    path = Path.join(root, "state")
    on_exit(fn -> File.rm_rf!(root) end)
    assert Hints.load(path, "https://gateway.test") == nil
    assert :ok = Hints.save(path, "https://gateway.test", "agent_fixture")
    assert Hints.load(path, "https://gateway.test") == "agent_fixture"
    assert Hints.load(path, "https://other.test") == nil
    assert Bitwise.band(File.stat!(path).mode, 0o077) == 0

    for body <- [
          String.duplicate("x", 4_097),
          <<255>>,
          ~s({"v":1,"gateway":"https://gateway.test","target":"agent_fixture","credential":"secret"}),
          ~s({"v":1,"gateway":"https://gateway.test","target":"agent_fixture","target":"agent_other"}),
          ~s({"v":2,"gateway":"https://gateway.test","target":"agent_fixture"})
        ] do
      File.write!(path, body)
      assert Hints.load(path, "https://gateway.test") == nil
    end
  end
end

defmodule Arbor.Actions.Security.DiffFindingsTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.DiffFindings

  test "parses a clean JSON array into L1 findings" do
    json = """
    [{"category":"fail_open_authz","title":"authorize rescues to :ok","file":"lib/a.ex","line":42,"severity":"high","rationale":"crash grants access","recommendation":"fail closed"}]
    """

    assert [f] = DiffFindings.parse(json)
    assert f.category == :fail_open_authz
    assert f.title == "authorize rescues to :ok"
    assert f.location.file == "lib/a.ex"
    assert f.location.line == 42
    assert f.severity.level == :high
    assert f.detector.layer == "L1"
    assert f.confidence.score == 0.5
    assert f.recommendation.approach == "fail closed"
  end

  test "strips ```json fences" do
    json =
      "```json\n[{\"category\":\"secret_exposure\",\"title\":\"token logged\",\"severity\":\"medium\"}]\n```"

    assert [f] = DiffFindings.parse(json)
    assert f.category == :secret_exposure
  end

  test "tolerates leading/trailing prose around the array" do
    text =
      "Here are the issues I found:\n[{\"category\":\"injection\",\"title\":\"shell interpolation\"}]\nLet me know if you need more."

    assert [f] = DiffFindings.parse(text)
    assert f.category == :injection
  end

  test "accepts a bare object (not wrapped in an array)" do
    json = ~s({"category":"crypto_weakness","title":"sha512 ed25519"})
    assert [f] = DiffFindings.parse(json)
    assert f.category == :crypto_weakness
  end

  test "unknown category falls back to :other (no String.to_atom)" do
    json = ~s([{"category":"made_up_category","title":"x"}])
    assert [f] = DiffFindings.parse(json)
    assert f.category == :other
  end

  test "empty array → no findings" do
    assert DiffFindings.parse("[]") == []
  end

  test "non-JSON / garbage → no findings" do
    assert DiffFindings.parse("I could not find any issues.") == []
    assert DiffFindings.parse("") == []
  end

  test "items without a title are skipped" do
    json = ~s([{"category":"other"}, {"category":"other","title":"real one"}])
    assert [f] = DiffFindings.parse(json)
    assert f.title == "real one"
  end

  test "multiple findings parse in order" do
    json = ~s([{"title":"a","category":"other"},{"title":"b","category":"path_traversal"}])
    assert [a, b] = DiffFindings.parse(json)
    assert a.title == "a"
    assert b.category == :path_traversal
  end
end

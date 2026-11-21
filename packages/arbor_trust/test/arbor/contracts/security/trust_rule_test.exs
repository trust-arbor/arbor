defmodule Arbor.Contracts.Security.TrustRuleTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.TrustRule

  describe "new/1 — rejects glob in trust rules (the footgun)" do
    test "rejects a trailing /**" do
      assert {:error, :glob_in_trust_rule} = TrustRule.new("arbor://fs/read/**")
    end

    test "rejects a trailing /*" do
      assert {:error, :glob_in_trust_rule} = TrustRule.new("arbor://fs/read/*")
    end

    test "rejects a mid-path glob" do
      assert {:error, :glob_in_trust_rule} = TrustRule.new("arbor://fs/**/read")
    end

    test "accepts a bare prefix" do
      assert {:ok, %TrustRule{uri: "arbor://fs/read"}} = TrustRule.new("arbor://fs/read")
    end
  end

  describe "new!/1" do
    test "raises on a glob URI" do
      assert_raise ArgumentError, ~r/glob/, fn -> TrustRule.new!("arbor://fs/read/**") end
    end

    test "returns the struct on a bare prefix" do
      assert %TrustRule{uri: "arbor://x"} = TrustRule.new!("arbor://x")
    end
  end

  describe "canonicalize/1" do
    test "strips a trailing /**" do
      assert TrustRule.canonicalize("arbor://fs/read/**") == "arbor://fs/read"
    end

    test "strips a trailing /*" do
      assert TrustRule.canonicalize("arbor://fs/read/*") == "arbor://fs/read"
    end

    test "leaves a bare prefix unchanged" do
      assert TrustRule.canonicalize("arbor://fs/read") == "arbor://fs/read"
    end
  end

  describe "glob?/1" do
    test "true for glob URIs" do
      assert TrustRule.glob?("arbor://fs/read/**")
      assert TrustRule.glob?("arbor://fs/read/*")
    end

    test "false for a bare prefix" do
      refute TrustRule.glob?("arbor://fs/read")
    end
  end
end

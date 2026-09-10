defmodule Arbor.Pipelines.MorningDigestTest do
  @moduledoc """
  The reference artifact is a bounded action graph. Filesystem behavior is tested
  through the public Actions facade in morning_digest_security_regression_test.
  These artifact checks never execute a script or touch the operator's reports.
  """
  use ExUnit.Case, async: true

  @moduletag :fast
  @pipeline Path.expand("../../../priv/pipelines/morning_digest.dot", __DIR__)
  @migration Path.expand("../../../priv/migrations/morning_digest_v2_unsigned.json", __DIR__)

  test "the reviewed graph uses the bounded action and exact context keys" do
    source = File.read!(@pipeline)
    assert source =~ "digraph MorningDigest"
    assert source =~ ~s(action="reports.build_morning_digest")
    assert source =~ ~s(context_keys="reports_directory,topics")
    refute source =~ ~s(type="shell")
    refute source =~ "morning_digest.sh"
  end

  test "unsigned migration binds current graph bytes and leaves deployment authority unresolved" do
    migration = @migration |> File.read!() |> Jason.decode!()
    digest = :crypto.hash(:sha256, File.read!(@pipeline)) |> Base.encode16(case: :lower)
    assert migration["graph_hash"] == digest
    assert migration["status"] == "unsigned_review_only"
    assert migration["workdir"] == nil
    assert migration["issuer_id"] == nil
    refute Map.has_key?(migration, "signature")

    assert migration["initial_args"] == %{
             "reports_directory" => "reports",
             "topics" => ["upstream-deps", "upstream-deps-summary"]
           }

    assert {:error, {:legacy_version, 1}} =
             Arbor.Scheduler.CapsFile.load(String.replace_suffix(@pipeline, ".dot", ".caps.json"))
  end
end

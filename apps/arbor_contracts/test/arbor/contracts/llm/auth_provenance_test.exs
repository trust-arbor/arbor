defmodule Arbor.Contracts.LLM.AuthProvenanceTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.LLM.AuthProvenance

  @moduletag :fast

  @valid %{
    "owner" => "arbor_owned",
    "generation" => 4,
    "source" => "arbor_oauth_store",
    "source_generation" => 9,
    "source_observed_at" => "2026-07-22T17:00:00-05:00"
  }

  test "constructs a versioned, closed provenance envelope" do
    assert {:ok, provenance} = AuthProvenance.new(@valid)
    assert provenance.version == 1
    assert provenance.owner == "arbor_owned"
    assert provenance.source_observed_at == "2026-07-22T22:00:00Z"
    assert AuthProvenance.to_map(provenance)["source_generation"] == 9
    assert AuthProvenance.valid?(provenance)
  end

  test "accepts atom enum aliases without creating atoms" do
    assert {:ok, provenance} =
             AuthProvenance.new(owner: :source_owned, generation: 1, source: :codex_file)

    assert provenance.owner == "source_owned"
    assert provenance.source == "codex_file"
  end

  test "closes authority and secret-shaped fields and rejects hostile terms" do
    for key <- [
          "access_token",
          "refresh_token",
          "token_hash",
          "argv",
          "env",
          "capabilities",
          "callback",
          "authority"
        ] do
      assert {:error, {:unknown_fields, [^key]}} =
               AuthProvenance.new(Map.put(@valid, key, "secret"))
    end

    for value <- [
          self(),
          fn -> :secret end,
          {:secret, :term},
          %{token: :secret},
          ["x" | :improper]
        ] do
      refute AuthProvenance.valid?(Map.put(@valid, "source", value))
      assert {:error, _} = AuthProvenance.canonical_bytes(Map.put(@valid, "source", value))
    end
  end

  test "accepts only the closed owner enum" do
    assert {:ok, _} = AuthProvenance.new(Map.put(@valid, "owner", :source_owned))

    for owner <- ["imported", :unknown, nil, 1] do
      refute AuthProvenance.valid?(Map.put(@valid, "owner", owner))
    end
  end

  test "pins canonical bytes and digest" do
    assert {:ok, bytes} = AuthProvenance.canonical_bytes(@valid)

    assert bytes ==
             ~s({"version":1,"owner":"arbor_owned","generation":4,"source":"arbor_oauth_store","source_generation":9,"source_observed_at":"2026-07-22T22:00:00Z"})

    assert {:ok, digest} = AuthProvenance.digest(@valid)
    assert digest == "sha256:e11485a007c586fdffb4a083d14f86d0057bceb41cdfa87343e9f8ec95bfd069"
  end

  test "round-trips through JSON" do
    assert {:ok, provenance} = AuthProvenance.new(@valid)
    json = provenance |> AuthProvenance.to_map() |> Jason.encode!()
    assert Jason.decode!(json) == AuthProvenance.to_map(provenance)
    assert {:ok, decoded} = AuthProvenance.new(Jason.decode!(json))
    assert AuthProvenance.to_map(decoded) == AuthProvenance.to_map(provenance)
  end
end

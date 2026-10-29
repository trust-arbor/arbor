defmodule Arbor.Contracts.LLM.AuthProvenanceTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.LLM.AuthProvenance

  @moduletag :fast

  @valid %{
    "provider" => "openai",
    "account_id" => "acct_123",
    "origin" => "arbor_login",
    "owner" => "arbor_owned",
    "generation" => 4,
    "source" => "arbor_oauth_store"
  }

  test "constructs a versioned, closed provenance envelope" do
    assert {:ok, provenance} = AuthProvenance.new(@valid)
    assert provenance.version == 2
    assert provenance.provider == "openai"
    assert provenance.account_id == "acct_123"
    assert provenance.origin == "arbor_login"
    assert provenance.owner == "arbor_owned"
    assert AuthProvenance.valid?(provenance)
  end

  test "accepts atom enum aliases without creating atoms" do
    assert {:ok, provenance} =
             AuthProvenance.new(
               provider: :openai,
               account_id: "acct_source",
               origin: :external_cli,
               owner: :source_owned,
               generation: 1,
               source: :codex_file,
               source_generation: 8,
               source_observed_at: "2026-07-22T17:00:00-05:00"
             )

    assert provenance.owner == "source_owned"
    assert provenance.source == "codex_file"
    assert provenance.source_observed_at == "2026-07-22T22:00:00Z"
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
    assert {:ok, _} = AuthProvenance.new(@valid)

    for owner <- ["imported", :unknown, nil, 1] do
      refute AuthProvenance.valid?(Map.put(@valid, "owner", owner))
    end
  end

  test "security regression: owner, origin, provider, and source semantics cannot be mixed" do
    for attrs <- [
          Map.put(@valid, "origin", "external_cli"),
          Map.put(@valid, "source", "codex_file"),
          Map.put(@valid, "provider", "anthropic"),
          Map.merge(@valid, %{"owner" => "source_owned", "source" => "codex_file"})
        ] do
      assert {:error, _reason} = AuthProvenance.new(attrs)
    end
  end

  test "pins canonical bytes and digest" do
    assert {:ok, bytes} = AuthProvenance.canonical_bytes(@valid)

    assert bytes ==
             ~s({"version":2,"provider":"openai","account_id":"acct_123","origin":"arbor_login","owner":"arbor_owned","source":"arbor_oauth_store","generation":4})

    assert {:ok, digest} = AuthProvenance.digest(@valid)
    assert digest == "sha256:0f1e305ff1f7500e6ceece24bb03eafdde91791195e8d3c9cb3fb9d22a60fe23"
  end

  test "round-trips through JSON" do
    assert {:ok, provenance} = AuthProvenance.new(@valid)
    json = provenance |> AuthProvenance.to_map() |> Jason.encode!()
    assert Jason.decode!(json) == AuthProvenance.to_map(provenance)
    assert {:ok, decoded} = AuthProvenance.new(Jason.decode!(json))
    assert AuthProvenance.to_map(decoded) == AuthProvenance.to_map(provenance)
  end
end

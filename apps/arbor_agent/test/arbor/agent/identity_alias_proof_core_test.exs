defmodule Arbor.Agent.IdentityAliasProofCoreTest do
  @moduledoc """
  Canonicalization tests for identity-alias possession-proof payloads.

  These are pure: no IO, no Security children. They prove the length-prefixing
  property — two distinct mutations MUST NOT canonicalize to the same bytes —
  and the explicit byte layout (version + operation + arguments).
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.IdentityAliasProofCore

  describe "canonical_payload/1 byte layout" do
    test "link payload is version + link + secondary_id + primary_id, each length-prefixed" do
      {:ok, payload} = IdentityAliasProofCore.canonical_payload({:link, "sec", "pri"})

      <<vlen::32-big, version::binary-size(vlen), rest::binary>> = payload
      assert version == IdentityAliasProofCore.version()
      assert version == "arbor.identity.alias.v1"

      <<olen::32-big, op::binary-size(olen), rest::binary>> = rest
      assert op == "link"

      <<slen::32-big, secondary::binary-size(slen), rest::binary>> = rest
      assert secondary == "sec"

      <<plen::32-big, primary::binary-size(plen)>> = rest
      assert primary == "pri"
    end

    test "unlink payload is version + unlink + secondary_id, each length-prefixed" do
      {:ok, payload} = IdentityAliasProofCore.canonical_payload({:unlink, "sec"})

      <<vlen::32-big, version::binary-size(vlen), rest::binary>> = payload
      assert version == "arbor.identity.alias.v1"

      <<olen::32-big, op::binary-size(olen), rest::binary>> = rest
      assert op == "unlink"

      <<slen::32-big, secondary::binary-size(slen)>> = rest
      assert secondary == "sec"
    end

    test "same mutation always produces the same payload bytes" do
      {:ok, a} = IdentityAliasProofCore.canonical_payload({:link, "sec", "pri"})
      {:ok, b} = IdentityAliasProofCore.canonical_payload({:link, "sec", "pri"})
      assert a == b
    end

    test "empty or non-binary fields fail closed" do
      assert {:error, :invalid_mutation} =
               IdentityAliasProofCore.canonical_payload({:link, "", "pri"})

      assert {:error, :invalid_mutation} =
               IdentityAliasProofCore.canonical_payload({:link, "sec", ""})

      assert {:error, :invalid_mutation} =
               IdentityAliasProofCore.canonical_payload({:unlink, ""})

      assert {:error, :invalid_mutation} =
               IdentityAliasProofCore.canonical_payload({:link, :sec, "pri"})

      assert {:error, :invalid_mutation} = IdentityAliasProofCore.canonical_payload(:link)
    end
  end

  describe "length-prefixing property" do
    test "two distinct mutations cannot canonicalize to the same payload bytes" do
      # Without length prefixes, "ab"+"c" and "a"+"bc" concatenate identically.
      {:ok, split_left} = IdentityAliasProofCore.canonical_payload({:link, "ab", "c"})
      {:ok, split_right} = IdentityAliasProofCore.canonical_payload({:link, "a", "bc"})
      refute split_left == split_right

      {:ok, foo_barbaz} = IdentityAliasProofCore.canonical_payload({:link, "foo", "barbaz"})
      {:ok, foobar_baz} = IdentityAliasProofCore.canonical_payload({:link, "foobar", "baz"})
      refute foo_barbaz == foobar_baz

      # Domain separation: a link proof must not equal an unlink proof.
      {:ok, link_payload} = IdentityAliasProofCore.canonical_payload({:link, "sec", "pri"})
      {:ok, unlink_payload} = IdentityAliasProofCore.canonical_payload({:unlink, "sec"})
      refute link_payload == unlink_payload

      {:ok, other_secondary} = IdentityAliasProofCore.canonical_payload({:link, "sec2", "pri"})
      refute link_payload == other_secondary

      {:ok, other_primary} = IdentityAliasProofCore.canonical_payload({:link, "sec", "pri2"})
      refute link_payload == other_primary
    end
  end
end

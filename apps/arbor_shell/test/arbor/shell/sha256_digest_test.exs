defmodule Arbor.Shell.Sha256DigestTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell.Sha256Digest

  @moduletag :fast
  @moduletag :security_regression

  @hex String.duplicate("a", 64)
  @prefixed "sha256:" <> @hex

  test "normalizes a prefixed digest and a bare 64-hex id to the same form" do
    assert Sha256Digest.normalize(@prefixed) == {:ok, @prefixed}
    assert Sha256Digest.normalize(@hex) == {:ok, @prefixed}
    assert Sha256Digest.bare(@prefixed) == {:ok, @hex}
    assert Sha256Digest.bare(@hex) == {:ok, @hex}
    assert Sha256Digest.equal?(@prefixed, @hex)
  end

  test "security regression: tags and truncated hex are refused" do
    assert {:error, :invalid_sha256_digest} = Sha256Digest.normalize("validation:latest")
    assert {:error, :invalid_sha256_digest} = Sha256Digest.normalize("sha256:not-a-digest")
    assert {:error, :invalid_sha256_digest} = Sha256Digest.normalize(String.duplicate("A", 64))
    refute Sha256Digest.equal?(@hex, String.duplicate("b", 64))
  end

  test "facade exposes the same normalize helper" do
    assert Arbor.Shell.normalize_sha256_digest(@hex) == {:ok, @prefixed}
  end
end

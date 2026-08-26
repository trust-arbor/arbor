defmodule Arbor.Shell.Sha256Digest do
  @moduledoc false

  # Shared sha256 digest grammar for OCI inspect/policy ids.
  #
  # Podman `image inspect` `.Id` is the bare 64-hex; `--iidfile` and Arbor
  # policy `image_id` use `sha256:` + 64 hex. Normalize both to the prefixed
  # form. Compare via `equal?/2`.

  @hex64_re ~r/\A[0-9a-f]{64}\z/

  @spec normalize(term()) :: {:ok, String.t()} | {:error, :invalid_sha256_digest}
  def normalize("sha256:" <> hex) when is_binary(hex), do: normalize_hex(hex)
  def normalize(hex) when is_binary(hex), do: normalize_hex(hex)
  def normalize(_value), do: {:error, :invalid_sha256_digest}

  @spec bare(term()) :: {:ok, String.t()} | {:error, :invalid_sha256_digest}
  def bare(value) do
    case normalize(value) do
      {:ok, "sha256:" <> hex} -> {:ok, hex}
      error -> error
    end
  end

  @spec equal?(term(), term()) :: boolean()
  def equal?(left, right) do
    case {normalize(left), normalize(right)} do
      {{:ok, same}, {:ok, same}} -> true
      _other -> false
    end
  end

  defp normalize_hex(hex) when is_binary(hex) do
    if Regex.match?(@hex64_re, hex) do
      {:ok, "sha256:" <> hex}
    else
      {:error, :invalid_sha256_digest}
    end
  end
end

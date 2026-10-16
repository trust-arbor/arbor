defmodule Arbor.Security.ImportedSkillScreen do
  @moduledoc """
  Reflex-screen imported skill name/body after normalizing common ciphers.

  Plaintext-only screening misses Ciphered Skill Injection (arXiv 2610.18262).
  This module also checks rot13, decoded base64, and decoded hex views, and
  rejects dense encoded blobs that will not decode.
  """

  alias Arbor.Security.Reflex

  @min_blob_bytes 24
  @max_views 32
  @max_blob_bytes 8_192

  @type error_reason ::
          :blocked | :invalid_skill | :malformed_reflex_result | :reflex_unavailable

  @doc "Screen skill name as command context and body as URL context."
  @spec validate(String.t(), String.t()) :: :ok | {:error, error_reason()}
  def validate(name, body) when is_binary(name) and is_binary(body) do
    with :ok <- screen(name, :command),
         :ok <- screen(body, :url) do
      :ok
    end
  end

  def validate(_name, _body), do: {:error, :invalid_skill}

  defp screen(text, field) do
    with :ok <- reject_undecodable_dense_blobs(text) do
      text
      |> views()
      |> Enum.reduce_while(:ok, fn view, :ok ->
        case check_context(%{field => view}) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp views(text) do
    [text, rot13(text)]
    |> Kernel.++(decoded_base64_views(text))
    |> Kernel.++(decoded_hex_views(text))
    |> Enum.uniq()
    |> Enum.take(@max_views)
  end

  defp decoded_base64_views(text) do
    # Standard base64 may include `/`; url-safe uses `-` `_`. Scan both.
    # Path-like tokens are still attempted; failed decode is not a view.
    (scan_blobs(text, ~r/[A-Za-z0-9+\/]{#{@min_blob_bytes},}={0,2}/) ++
       scan_blobs(text, ~r/[A-Za-z0-9_-]{#{@min_blob_bytes},}={0,2}/))
    |> Enum.uniq()
    |> Enum.flat_map(&decode_base64_blob/1)
  end

  defp decoded_hex_views(text) do
    ~r/\b[0-9a-fA-F]{#{@min_blob_bytes},}\b/
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.flat_map(&decode_hex_blob/1)
  end

  defp decode_base64_blob(blob) when byte_size(blob) > @max_blob_bytes, do: []

  defp decode_base64_blob(blob) do
    [fn -> Base.decode64(blob) end, fn -> Base.url_decode64(blob, padding: false) end]
    |> Enum.find_value([], fn decode ->
      case decode.() do
        {:ok, decoded} -> usable_decoded(decoded)
        :error -> nil
      end
    end)
  end

  defp decode_hex_blob(blob) when byte_size(blob) > @max_blob_bytes, do: []

  defp decode_hex_blob(blob) do
    case Base.decode16(blob, case: :mixed) do
      {:ok, decoded} -> usable_decoded(decoded)
      :error -> []
    end
  end

  defp usable_decoded(decoded) when is_binary(decoded) do
    if String.valid?(decoded) and String.printable?(decoded) and decoded != "" do
      [decoded]
    else
      []
    end
  end

  defp usable_decoded(_), do: []

  defp reject_undecodable_dense_blobs(text) do
    # Do not treat filesystem paths or kebab-case names as base64.
    # `/` and `-` are in the (url-safe) alphabets, so `/tmp/.../SKILL.md`
    # and `arbor-skill-import-<hex>` are 24+ "blobs" that will not decode.
    # Opaque tokens without those separators (31 A's, padded ciphertext)
    # still fail closed.
    base64_blobs = scan_blobs(text, ~r/[A-Za-z0-9+]{#{@min_blob_bytes},}={0,2}/)

    hex_blobs = scan_blobs(text, ~r/\b[0-9a-fA-F]{#{@min_blob_bytes},}\b/)

    undecodable_base64? =
      Enum.any?(base64_blobs, fn blob ->
        byte_size(blob) <= @max_blob_bytes and not decodable_base64?(blob)
      end)

    undecodable_hex? =
      Enum.any?(hex_blobs, fn blob ->
        byte_size(blob) <= @max_blob_bytes and not decodable_hex?(blob)
      end)

    if undecodable_base64? or undecodable_hex? do
      {:error, :blocked}
    else
      :ok
    end
  end

  defp scan_blobs(text, regex) do
    regex
    |> Regex.scan(text)
    |> List.flatten()
  end

  defp decodable_base64?(blob) do
    match?({:ok, _}, Base.decode64(blob)) or
      match?({:ok, _}, Base.url_decode64(blob, padding: false))
  end

  defp decodable_hex?(blob) do
    rem(byte_size(blob), 2) == 0 and match?({:ok, _}, Base.decode16(blob, case: :mixed))
  end

  defp rot13(text) when is_binary(text) do
    for <<c <- text>>, into: "" do
      cond do
        c in ?A..?Z -> <<rem(c - ?A + 13, 26) + ?A>>
        c in ?a..?z -> <<rem(c - ?a + 13, 26) + ?a>>
        true -> <<c>>
      end
    end
  end

  defp check_context(context) do
    context
    |> Reflex.check()
    |> normalize()
  rescue
    _ -> {:error, :reflex_unavailable}
  catch
    _, _ -> {:error, :reflex_unavailable}
  end

  defp normalize(:ok), do: :ok
  defp normalize({:warned, _warnings}), do: :ok
  defp normalize({:blocked, _reflex, _message}), do: {:error, :blocked}
  defp normalize(_other), do: {:error, :malformed_reflex_result}
end

defmodule ArborTui.Signer do
  @moduledoc """
  Client-side request signing for the Arbor Gateway.

  Reproduces the small, well-specified signing surface the server expects
  (`Arbor.Contracts.Security.SignedRequest` + `Arbor.Gateway.SignedRequestAuth`)
  using only stdlib `:crypto` Ed25519 — the standard primitive, not home-rolled
  crypto. This keeps the client fully decoupled from the server umbrella (no
  path-deps); the cost is that the wire format below MUST stay byte-identical to
  the server. Any drift breaks every signed request.

  ## Identity

  Loaded from a `.arbor.key` file (line-oriented `key=value`):

      agent_id=agent_30b455…
      private_key_b64=<base64 32- or 64-byte Ed25519 private key>

  ## Wire format (must match `Arbor.Gateway.SignedRequestAuth`)

  Header: `Authorization: Signature <base64-nopad(JSON envelope)>` where the
  envelope is `{agent_id, timestamp(iso8601), nonce(base64), signature(base64)}`.

  The bytes actually fed to Ed25519 are the length-prefixed canonical signing
  payload over the request fingerprint `method <> "\\n" <> path <> "\\n" <> body`.
  """

  @typedoc "Parsed `.arbor.key` material."
  @type identity :: %{agent_id: String.t(), private_key: binary()}

  @nonce_size 16

  # ── Identity loading (mirrors Arbor.Security.KeyFile.parse/1) ──────────────

  @spec load_key(Path.t()) :: {:ok, identity()} | {:error, term()}
  def load_key(path) do
    with {:ok, contents} <- File.read(path) do
      parse_key(contents)
    else
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  @spec parse_key(String.t()) :: {:ok, identity()} | {:error, term()}
  def parse_key(contents) when is_binary(contents) do
    fields =
      contents
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
          _ -> acc
        end
      end)

    with {:ok, agent_id} <- fetch(fields, "agent_id"),
         {:ok, b64} <- fetch(fields, "private_key_b64"),
         {:ok, key} <- decode_key(b64),
         :ok <- validate_agent_id(agent_id) do
      {:ok, %{agent_id: agent_id, private_key: key}}
    end
  end

  # ── Signing ────────────────────────────────────────────────────────────────

  @doc """
  Build the `Authorization` header value for a request.

  `body` is "" for the WebSocket upgrade GET. The returned string is ready to
  slot into the `authorization` header.
  """
  @spec authorization_header(identity(), String.t(), String.t(), binary()) :: String.t()
  def authorization_header(identity, method, path, body \\ "") do
    payload = canonical_payload(method, path, body)
    {timestamp, nonce, signature} = sign(payload, identity)

    envelope =
      %{
        "agent_id" => identity.agent_id,
        "timestamp" => DateTime.to_iso8601(timestamp),
        "nonce" => Base.encode64(nonce),
        "signature" => Base.encode64(signature)
      }
      |> Jason.encode!()
      |> Base.encode64(padding: false)

    "Signature " <> envelope
  end

  @doc "The request fingerprint the server reconstructs and verifies against."
  @spec canonical_payload(String.t(), String.t(), binary()) :: binary()
  def canonical_payload(method, path, body) do
    IO.iodata_to_binary([method, "\n", path, "\n", body])
  end

  # Returns {timestamp, nonce, signature}. The signed message is the
  # length-prefixed canonical payload — identical to
  # SignedRequest.compute_signing_payload/1.
  defp sign(payload, %{agent_id: agent_id, private_key: private_key}) do
    timestamp = DateTime.utc_now()
    nonce = :crypto.strong_rand_bytes(@nonce_size)

    message =
      len_prefix(payload) <>
        len_prefix(agent_id) <>
        len_prefix(DateTime.to_iso8601(timestamp)) <>
        nonce

    signature = :crypto.sign(:eddsa, :sha512, message, [private_key, :ed25519])
    {timestamp, nonce, signature}
  end

  defp len_prefix(field) when is_binary(field), do: <<byte_size(field)::32, field::binary>>

  # ── Key-file field helpers ───────────────────────────────────────────────

  defp fetch(fields, key) do
    case Map.get(fields, key) do
      nil -> {:error, {:missing_field, key}}
      "" -> {:error, {:empty_field, key}}
      value -> {:ok, value}
    end
  end

  defp decode_key(b64) do
    case Base.decode64(b64) do
      {:ok, bin} when byte_size(bin) in [32, 64] -> {:ok, bin}
      {:ok, bin} -> {:error, {:invalid_private_key_size, byte_size(bin)}}
      :error -> {:error, :invalid_private_key_base64}
    end
  end

  defp validate_agent_id(id) do
    if String.starts_with?(id, "agent_") and byte_size(id) > 6,
      do: :ok,
      else: {:error, {:invalid_agent_id, id}}
  end
end

defmodule Arbor.Contracts.Security.InvocationReceipt do
  @moduledoc """
  Cryptographically signed proof that a capability was used.

  When a capability authorization succeeds, an invocation receipt is generated
  and signed by the system authority. The receipt proves:

  - **Who**: which agent used the capability
  - **What**: which resource was accessed
  - **When**: timestamp of the authorization
  - **How**: which capability authorized it, including the full delegation chain
  - **Integrity**: Ed25519 signature prevents tampering

  Receipts are immutable, append-only records stored via the security event log.

  ## Verification

  Anyone with the system authority's public key can verify a receipt:

      receipt = %InvocationReceipt{...}
      public_key = SystemAuthority.public_key()
      InvocationReceipt.verify(receipt, public_key)
      # => :ok | {:error, :invalid_receipt_signature}

  Only the current payload format (`signing_version/0`) verifies. The receipt
  must carry its native field types (atom keys, raw signature bytes,
  `DateTime`s): every value is signed with its type, so a JSON round-tripped
  copy does not verify.
  """

  use TypedStruct

  alias Arbor.Types

  @derive {Jason.Encoder,
           only: [
             :id,
             :capability_id,
             :principal_id,
             :resource_uri,
             :action,
             :result,
             :timestamp,
             :nonce,
             :delegation_chain,
             :session_id,
             :task_id,
             :issuer_id,
             :signature
           ]}
  typedstruct enforce: true do
    @typedoc "A signed proof of capability invocation"

    field(:id, binary())
    field(:capability_id, Types.capability_id())
    field(:principal_id, Types.agent_id())
    field(:resource_uri, Types.resource_uri())
    field(:action, atom() | nil, enforce: false)
    field(:result, :granted | :pending_approval)
    field(:timestamp, DateTime.t())
    field(:nonce, binary())
    field(:delegation_chain, [Types.delegation_record()], default: [])
    field(:session_id, binary(), enforce: false)
    field(:task_id, binary(), enforce: false)
    field(:issuer_id, Types.agent_id(), enforce: false)
    field(:signature, binary(), enforce: false)
  end

  @doc """
  Create a new invocation receipt.

  ## Options

  - `:capability_id` (required) - ID of the capability that authorized the action
  - `:principal_id` (required) - ID of the agent that used the capability
  - `:resource_uri` (required) - URI of the resource accessed
  - `:action` - The action performed (optional atom). Any other term returns
    `{:error, :invalid_action}`: the action is part of the signed payload, and
    a non-atom such as a map cannot be encoded into it.
  - `:result` - Authorization result (`:granted` or `:pending_approval`)
  - `:delegation_chain` - Full delegation chain from the capability
  - `:session_id` - Session context (if session-bound)
  - `:task_id` - Task context (if task-bound)
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_action | term()}
  def new(attrs) do
    with {:ok, action} <- validate_action(attrs[:action]) do
      receipt = %__MODULE__{
        id: generate_receipt_id(),
        capability_id: Keyword.fetch!(attrs, :capability_id),
        principal_id: Keyword.fetch!(attrs, :principal_id),
        resource_uri: Keyword.fetch!(attrs, :resource_uri),
        action: action,
        result: Keyword.get(attrs, :result, :granted),
        timestamp: DateTime.utc_now(),
        nonce: :crypto.strong_rand_bytes(16),
        delegation_chain: attrs[:delegation_chain] || [],
        session_id: attrs[:session_id],
        task_id: attrs[:task_id]
      }

      {:ok, receipt}
    end
  rescue
    e -> {:error, e}
  end

  # Signed-payload version, the first field of the signed bytes (domain
  # separation, as `Capability`'s "arbor-cap-sig-v2"). The authority signs
  # capabilities and receipts with one key; distinct leading version strings
  # keep either payload from ever parsing as the other.
  #
  # v2 (2026-10-01): the unversioned v1 payload signed the delegation chain
  # as `k=v` text joined with "," and ";", unescaped and untyped. A delegator
  # signature is 64 raw bytes and maps were signed as their JSON text, so a
  # presenter could re-shape a signed chain (hide a delegation hop, fold a
  # field into its neighbour, swap a map for its JSON or atom keys for
  # strings) and the signature still verified. v2 encodes every field as a
  # typed, length-delimited term. v1 is not accepted: no signature-bearing v1
  # receipt was ever persisted, and accepting one would keep the forgery
  # open. See `.arbor/decisions/2026-10-01-invocation-receipt-payload-v2.md`.
  @signing_version "arbor-receipt-sig-v2"

  @doc """
  Compute the canonical signing payload for a receipt.

  Deterministic binary for Ed25519 signing. Excludes the `signature` field.
  Starts with the length-prefixed `signing_version/0`; every field after it is
  a typed term `<<tag::8, byte_size(body)::32, body::binary>>`, so equal
  payloads imply equal field values, delegation chain included:

  | tag | term | body |
  |-----|------|------|
  | `b` | binary | the bytes |
  | `a` | atom (incl. `nil`, `true`, `false`) | `Atom.to_string/1` |
  | `i` | integer | `Integer.to_string/1` |
  | `f` | float | `:erlang.float_to_binary(float, [:short])` |
  | `l` | proper list | element terms, in order |
  | `m` | plain map | key term + value term pairs, sorted by key term |
  | `d` | `DateTime` | `to_iso8601` term + `time_zone` term |

  Includes `issuer_id` (who issued the receipt) so it cannot be relabelled
  without invalidating the signature. NOTE: `issuer_id` must be set on the
  receipt BEFORE the signature is computed — see `SystemAuthority.sign_receipt`.
  (Security Sentinel finding, 2026-06-09 — `issuer_id` was previously unsigned.)

  Raises `ArgumentError` for a field of the wrong type or a chain value with
  no canonical encoding (a tuple, pid, reference, or struct other than
  `DateTime`); the authority refuses to sign such a receipt.
  """
  @spec signing_payload(t()) :: binary()
  def signing_payload(%__MODULE__{} = receipt) do
    length_prefix(@signing_version) <>
      field!(:id, receipt.id, :binary) <>
      field!(:capability_id, receipt.capability_id, :binary) <>
      field!(:principal_id, receipt.principal_id, :binary) <>
      field!(:resource_uri, receipt.resource_uri, :binary) <>
      field!(:action, receipt.action, :atom) <>
      field!(:result, receipt.result, :atom) <>
      field!(:timestamp, receipt.timestamp, :datetime) <>
      field!(:nonce, receipt.nonce, :binary) <>
      field!(:session_id, receipt.session_id, :optional_binary) <>
      field!(:task_id, receipt.task_id, :optional_binary) <>
      field!(:issuer_id, receipt.issuer_id, :optional_binary) <>
      field!(:delegation_chain, receipt.delegation_chain, :chain)
  end

  @doc "The signed-payload version string, the first field of `signing_payload/1`."
  @spec signing_version() :: String.t()
  def signing_version, do: @signing_version

  @doc """
  Verify a receipt's signature against a public key.

  Returns `:ok` if the signature is valid, `{:error, :invalid_receipt_signature}` otherwise.
  """
  @spec verify(t(), binary()) :: :ok | {:error, :invalid_receipt_signature}
  def verify(%__MODULE__{signature: nil}, _public_key) do
    {:error, :invalid_receipt_signature}
  end

  def verify(%__MODULE__{} = receipt, public_key) do
    payload = signing_payload(receipt)

    if :crypto.verify(:eddsa, :sha512, payload, receipt.signature, [public_key, :ed25519]) do
      :ok
    else
      {:error, :invalid_receipt_signature}
    end
  rescue
    # An unencodable field (e.g. a tampered non-atom action) or a malformed
    # signature cannot have come from `SystemAuthority.sign_receipt`; reject it
    # instead of raising in whoever is verifying.
    _ -> {:error, :invalid_receipt_signature}
  end

  @doc """
  Returns true if the receipt has been signed.
  """
  @spec signed?(t()) :: boolean()
  def signed?(%__MODULE__{signature: nil}), do: false
  def signed?(%__MODULE__{signature: sig}) when byte_size(sig) == 0, do: false
  def signed?(%__MODULE__{}), do: true

  # Private

  defp validate_action(action) when is_atom(action), do: {:ok, action}
  defp validate_action(_action), do: {:error, :invalid_action}

  defp generate_receipt_id do
    "rcpt_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp length_prefix(field) when is_binary(field) do
    <<byte_size(field)::32, field::binary>>
  end

  # Each receipt field has one accepted shape. Anything else raises, which
  # `SystemAuthority.sign_receipt/1` answers with `{:error, :invalid_receipt}`.
  defp field!(_name, value, :binary) when is_binary(value), do: encode_term(value)

  defp field!(_name, value, :optional_binary) when is_binary(value) or is_nil(value),
    do: encode_term(value)

  defp field!(_name, value, :atom) when is_atom(value), do: encode_term(value)
  defp field!(_name, %DateTime{} = value, :datetime), do: encode_term(value)

  # Every element is a delegation record (`Types.delegation_record`), a plain
  # map; `encode_term/1` then refuses any value without a canonical encoding.
  defp field!(name, chain, :chain) when is_list(chain) do
    if Enum.all?(chain, &(is_map(&1) and not is_struct(&1))),
      do: encode_term(chain),
      else: raise(ArgumentError, "receipt field #{inspect(name)} must be a list of plain maps")
  end

  defp field!(name, _value, kind) do
    raise ArgumentError, "receipt field #{inspect(name)} must be #{kind}"
  end

  # Typed, length-delimited term encoding (see `signing_payload/1`). Each tag
  # names one type and every body is delimited, so the encoding is injective:
  # no two distinct terms share bytes. Adding a tag for a type refused today
  # keeps every signable receipt's bytes; changing an existing tag needs a
  # new @signing_version.
  defp encode_term(value) when is_binary(value), do: tagged(?b, value)
  defp encode_term(value) when is_atom(value), do: tagged(?a, Atom.to_string(value))
  defp encode_term(value) when is_integer(value), do: tagged(?i, Integer.to_string(value))

  defp encode_term(value) when is_float(value),
    do: tagged(?f, :erlang.float_to_binary(value, [:short]))

  defp encode_term(value) when is_list(value), do: tagged(?l, encode_list(value, ""))

  defp encode_term(%DateTime{} = value),
    do: tagged(?d, encode_term(DateTime.to_iso8601(value)) <> encode_term(value.time_zone))

  defp encode_term(value) when is_map(value) and not is_struct(value) do
    body =
      value
      |> Enum.map(fn {key, val} -> {encode_term(key), encode_term(val)} end)
      |> Enum.sort()
      |> Enum.map_join(fn {key, val} -> key <> val end)

    tagged(?m, body)
  end

  defp encode_term(_value) do
    raise ArgumentError, "delegation chain value has no canonical receipt encoding"
  end

  defp encode_list([], acc), do: acc
  defp encode_list([head | tail], acc), do: encode_list(tail, acc <> encode_term(head))

  defp encode_list(_improper_tail, _acc) do
    raise ArgumentError, "delegation chain value has no canonical receipt encoding"
  end

  defp tagged(tag, body), do: <<tag::8, byte_size(body)::32, body::binary>>
end

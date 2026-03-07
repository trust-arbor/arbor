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
  """

  use TypedStruct

  alias Arbor.Types

  @derive Jason.Encoder
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
  - `:action` - The action performed (optional)
  - `:result` - Authorization result (`:granted` or `:pending_approval`)
  - `:delegation_chain` - Full delegation chain from the capability
  - `:session_id` - Session context (if session-bound)
  - `:task_id` - Task context (if task-bound)
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    receipt = %__MODULE__{
      id: generate_receipt_id(),
      capability_id: Keyword.fetch!(attrs, :capability_id),
      principal_id: Keyword.fetch!(attrs, :principal_id),
      resource_uri: Keyword.fetch!(attrs, :resource_uri),
      action: attrs[:action],
      result: Keyword.get(attrs, :result, :granted),
      timestamp: DateTime.utc_now(),
      nonce: :crypto.strong_rand_bytes(16),
      delegation_chain: attrs[:delegation_chain] || [],
      session_id: attrs[:session_id],
      task_id: attrs[:task_id]
    }

    {:ok, receipt}
  rescue
    e -> {:error, e}
  end

  @doc """
  Compute the canonical signing payload for a receipt.

  Deterministic binary for Ed25519 signing. Excludes the `signature` field.
  Length-prefixed to prevent field-boundary ambiguity.
  """
  @spec signing_payload(t()) :: binary()
  def signing_payload(%__MODULE__{} = receipt) do
    action_bin = if receipt.action, do: to_string(receipt.action), else: ""

    length_prefix(receipt.id) <>
      length_prefix(receipt.capability_id) <>
      length_prefix(receipt.principal_id) <>
      length_prefix(receipt.resource_uri) <>
      length_prefix(action_bin) <>
      length_prefix(to_string(receipt.result)) <>
      length_prefix(DateTime.to_iso8601(receipt.timestamp)) <>
      length_prefix(receipt.nonce) <>
      length_prefix(receipt.session_id || "") <>
      length_prefix(receipt.task_id || "") <>
      length_prefix(encode_delegation_chain(receipt.delegation_chain))
  end

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
  end

  @doc """
  Returns true if the receipt has been signed.
  """
  @spec signed?(t()) :: boolean()
  def signed?(%__MODULE__{signature: nil}), do: false
  def signed?(%__MODULE__{signature: sig}) when byte_size(sig) == 0, do: false
  def signed?(%__MODULE__{}), do: true

  # Private

  defp generate_receipt_id do
    "rcpt_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp length_prefix(field) when is_binary(field) do
    <<byte_size(field)::32, field::binary>>
  end

  # Encode delegation chain as a deterministic string for signing
  defp encode_delegation_chain([]), do: ""

  defp encode_delegation_chain(chain) when is_list(chain) do
    chain
    |> Enum.map(fn record ->
      record
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
      |> Enum.join(",")
    end)
    |> Enum.join(";")
  end
end

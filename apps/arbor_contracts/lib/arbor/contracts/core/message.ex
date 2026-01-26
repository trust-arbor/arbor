defmodule Arbor.Contracts.Core.Message do
  @moduledoc """
  Standard message envelope for inter-agent communication.

  All communication between agents is wrapped in message envelopes that provide:
  - Routing information (to/from addresses)
  - Correlation data (session, trace, execution IDs)
  - Metadata for debugging and monitoring
  - Structured payload delivery

  ## Address Format

  Agent addresses follow the format: `arbor://agent/{agent_id}`

  ## Usage

      {:ok, message} = Message.new(
        to: "arbor://agent/agent_abc123",
        from: "arbor://agent/agent_def456",
        payload: %{action: :process_data, data: "..."},
        session_id: "session_xyz789"
      )
  """

  use TypedStruct

  alias Arbor.Types

  @derive {Jason.Encoder, except: []}
  typedstruct enforce: true do
    @typedoc "Message envelope for inter-agent communication"

    field(:id, String.t())
    field(:to, Types.agent_uri())
    field(:from, Types.agent_uri())
    field(:session_id, Types.session_id(), enforce: false)
    field(:trace_id, Types.trace_id(), enforce: false)
    field(:execution_id, Types.execution_id(), enforce: false)
    field(:payload, any())
    field(:timestamp, DateTime.t())
    field(:reply_to, String.t(), enforce: false)
    field(:metadata, map(), default: %{})
  end

  @doc """
  Create a new message envelope with validation.

  ## Options

  - `:to` (required) - Target agent URI
  - `:from` (required) - Source agent URI
  - `:payload` (required) - Message payload
  - `:session_id` - Session this message belongs to
  - `:trace_id` - Distributed tracing ID
  - `:execution_id` - Execution context ID
  - `:reply_to` - Message ID this is replying to
  - `:metadata` - Additional metadata

  ## Examples

      {:ok, message} = Message.new(
        to: "arbor://agent/worker_001",
        from: "arbor://agent/coordinator_001",
        payload: %{task: :analyze, target: "file.ex"}
      )
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    message = %__MODULE__{
      id: attrs[:id] || generate_message_id(),
      to: Keyword.fetch!(attrs, :to),
      from: Keyword.fetch!(attrs, :from),
      session_id: attrs[:session_id],
      trace_id: attrs[:trace_id],
      execution_id: attrs[:execution_id],
      payload: Keyword.fetch!(attrs, :payload),
      timestamp: attrs[:timestamp] || DateTime.utc_now(),
      reply_to: attrs[:reply_to],
      metadata: attrs[:metadata] || %{}
    }

    case validate_message(message) do
      :ok -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Create a reply message to an existing message.

  Automatically sets the reply_to field and reverses to/from addresses.
  """
  @spec reply(t(), any(), keyword()) :: {:ok, t()} | {:error, term()}
  def reply(%__MODULE__{} = original, payload, opts \\ []) do
    new(
      to: original.from,
      from: original.to,
      payload: payload,
      session_id: original.session_id,
      trace_id: original.trace_id,
      execution_id: original.execution_id,
      reply_to: original.id,
      metadata: opts[:metadata] || %{}
    )
  end

  # Private functions

  defp generate_message_id do
    "msg_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp validate_message(%__MODULE__{to: to, from: from}) do
    cond do
      not valid_agent_uri?(to) ->
        {:error, {:invalid_to_uri, to}}

      not valid_agent_uri?(from) ->
        {:error, {:invalid_from_uri, from}}

      to == from ->
        {:error, :self_messaging_not_allowed}

      true ->
        :ok
    end
  end

  defp valid_agent_uri?(uri) when is_binary(uri) do
    String.match?(uri, ~r/^arbor:\/\/agent\/[a-zA-Z0-9_-]+$/)
  end

  defp valid_agent_uri?(_), do: false
end

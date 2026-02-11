defmodule Arbor.Contracts.Session.Message do
  @moduledoc """
  TypedStruct for a single message in a session conversation.

  Messages are the fundamental unit of conversation history. Each message has
  a role (user, assistant, system, or tool), content, and optional taint
  classification for data flow tracking.

  ## Roles

  - `:user` — Human or agent input
  - `:assistant` — LLM response
  - `:system` — System-level instructions or context
  - `:tool` — Tool execution result (requires `tool_call_id`)

  ## Taint Levels

  - `:public` — No sensitive data, safe for any provider
  - `:internal` — Internal data, prefer local/trusted providers
  - `:sensitive` — PII or credentials, requires encrypted transport
  - `:restricted` — Highest classification, on-premise only

  ## Convenience Constructors

      Message.user("Hello, world!")
      Message.assistant("Hi there!")
      Message.system("You are a helpful assistant.")
      Message.tool("tc_abc123", "file contents here")

  ## Usage

      {:ok, msg} = Message.new(role: :user, content: "Hello!")

      {:ok, msg} = Message.new(
        role: :tool,
        content: "result data",
        tool_call_id: "tc_abc123",
        taint_level: :sensitive
      )
  """

  use TypedStruct

  alias Arbor.Identifiers

  @valid_roles [:user, :assistant, :system, :tool]
  @valid_taint_levels [:public, :internal, :sensitive, :restricted]

  @derive {Jason.Encoder, except: []}
  typedstruct do
    @typedoc "A single message in a session conversation"

    field(:message_id, String.t(), enforce: true)
    field(:role, :user | :assistant | :system | :tool, enforce: true)
    field(:content, String.t(), enforce: true)
    field(:tool_call_id, String.t() | nil)
    field(:name, String.t() | nil)
    field(:taint_level, :public | :internal | :sensitive | :restricted, default: :public)
    field(:timestamp, DateTime.t(), enforce: true)
    field(:metadata, map(), default: %{})
  end

  # ============================================================================
  # Convenience Constructors
  # ============================================================================

  @doc """
  Create a user message.

  ## Examples

      {:ok, msg} = Message.user("Hello!")
      msg.role  # => :user

      {:ok, msg} = Message.user("Hello!", taint_level: :internal)
  """
  @spec user(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def user(content, opts \\ []) when is_binary(content) do
    opts
    |> Keyword.merge(role: :user, content: content)
    |> new()
  end

  @doc """
  Create an assistant message.

  ## Examples

      {:ok, msg} = Message.assistant("I can help with that!")
      msg.role  # => :assistant
  """
  @spec assistant(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def assistant(content, opts \\ []) when is_binary(content) do
    opts
    |> Keyword.merge(role: :assistant, content: content)
    |> new()
  end

  @doc """
  Create a system message.

  ## Examples

      {:ok, msg} = Message.system("You are a helpful assistant.")
      msg.role  # => :system
  """
  @spec system(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def system(content, opts \\ []) when is_binary(content) do
    opts
    |> Keyword.merge(role: :system, content: content)
    |> new()
  end

  @doc """
  Create a tool result message.

  Requires both `tool_call_id` and `content`. The `tool_call_id` links this
  message back to the tool call that produced the result.

  ## Examples

      {:ok, msg} = Message.tool("tc_abc123", "file listing: ...")
      msg.role          # => :tool
      msg.tool_call_id  # => "tc_abc123"

      {:ok, msg} = Message.tool("tc_abc123", "data", taint_level: :sensitive)
  """
  @spec tool(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def tool(tool_call_id, content, opts \\ [])
      when is_binary(tool_call_id) and is_binary(content) do
    opts
    |> Keyword.merge(role: :tool, content: content, tool_call_id: tool_call_id)
    |> new()
  end

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new message with validation.

  Accepts a keyword list or map. The `role` and `content` fields are required.
  `message_id` and `timestamp` are auto-generated if not provided.

  ## Required Fields

  - `:role` — One of `:user`, `:assistant`, `:system`, `:tool`
  - `:content` — Message text content

  ## Optional Fields

  - `:message_id` — Override the auto-generated message ID
  - `:tool_call_id` — Required when role is `:tool`, links to the originating tool call
  - `:name` — Optional name for the message sender
  - `:taint_level` — Data classification (default: `:public`)
  - `:timestamp` — Override the auto-generated timestamp
  - `:metadata` — Arbitrary metadata (default: `%{}`)

  ## Validation Rules

  - Role must be one of `:user`, `:assistant`, `:system`, `:tool`
  - Content must be a non-empty string
  - Tool messages must include a `tool_call_id`
  - Taint level must be one of `:public`, `:internal`, `:sensitive`, `:restricted`

  ## Examples

      {:ok, msg} = Message.new(role: :user, content: "Hello!")

      {:ok, msg} = Message.new(
        role: :tool,
        content: "result",
        tool_call_id: "tc_abc123",
        taint_level: :sensitive
      )

      {:error, {:missing_required, :content}} = Message.new(role: :user)

      {:error, {:invalid_role, :bogus}} = Message.new(role: :bogus, content: "hi")

      {:error, :tool_message_requires_tool_call_id} =
        Message.new(role: :tool, content: "result")
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_role(get_attr(attrs, :role)),
         :ok <- validate_content(get_attr(attrs, :content)),
         :ok <- validate_tool_call_id(get_attr(attrs, :role), get_attr(attrs, :tool_call_id)),
         :ok <- validate_taint_level(get_attr(attrs, :taint_level)),
         :ok <- validate_optional_string(attrs, :message_id),
         :ok <- validate_optional_string(attrs, :name),
         :ok <- validate_optional_map(attrs, :metadata) do
      now = DateTime.utc_now()

      message = %__MODULE__{
        message_id: get_attr(attrs, :message_id) || Identifiers.generate_id("msg_"),
        role: get_attr(attrs, :role),
        content: get_attr(attrs, :content),
        tool_call_id: get_attr(attrs, :tool_call_id),
        name: get_attr(attrs, :name),
        taint_level: get_attr(attrs, :taint_level) || :public,
        timestamp: get_attr(attrs, :timestamp) || now,
        metadata: get_attr(attrs, :metadata) || %{}
      }

      {:ok, message}
    end
  end

  # ============================================================================
  # Queries
  # ============================================================================

  @doc """
  Returns `true` if the message is from a tool result.

  ## Examples

      {:ok, msg} = Message.user("hi")
      Message.tool_result?(msg)  # => false

      {:ok, msg} = Message.tool("tc_1", "result")
      Message.tool_result?(msg)  # => true
  """
  @spec tool_result?(t()) :: boolean()
  def tool_result?(%__MODULE__{role: :tool}), do: true
  def tool_result?(%__MODULE__{}), do: false

  @doc """
  Returns `true` if the message has a taint level above `:public`.

  ## Examples

      {:ok, msg} = Message.user("hello")
      Message.tainted?(msg)  # => false

      {:ok, msg} = Message.user("secret", taint_level: :sensitive)
      Message.tainted?(msg)  # => true
  """
  @spec tainted?(t()) :: boolean()
  def tainted?(%__MODULE__{taint_level: :public}), do: false
  def tainted?(%__MODULE__{}), do: true

  # ============================================================================
  # Private — Validation
  # ============================================================================

  defp validate_role(nil), do: {:error, {:missing_required, :role}}
  defp validate_role(role) when role in @valid_roles, do: :ok
  defp validate_role(role), do: {:error, {:invalid_role, role}}

  defp validate_content(nil), do: {:error, {:missing_required, :content}}
  defp validate_content(content) when is_binary(content) and byte_size(content) > 0, do: :ok
  defp validate_content(""), do: {:error, {:missing_required, :content}}
  defp validate_content(invalid), do: {:error, {:invalid_content, invalid}}

  defp validate_tool_call_id(:tool, nil), do: {:error, :tool_message_requires_tool_call_id}
  defp validate_tool_call_id(:tool, id) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp validate_tool_call_id(:tool, ""), do: {:error, :tool_message_requires_tool_call_id}

  defp validate_tool_call_id(:tool, invalid),
    do: {:error, {:invalid_tool_call_id, invalid}}

  defp validate_tool_call_id(_role, _tool_call_id), do: :ok

  defp validate_taint_level(nil), do: :ok
  defp validate_taint_level(level) when level in @valid_taint_levels, do: :ok
  defp validate_taint_level(level), do: {:error, {:invalid_taint_level, level}}

  defp validate_optional_string(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_binary(val) -> :ok
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_optional_map(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_map(val) -> :ok
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  # ============================================================================
  # Private — Helpers
  # ============================================================================

  # Supports both atom and string keys in attrs map
  defp get_attr(attrs, key) when is_atom(key) do
    case Map.get(attrs, key) do
      nil -> Map.get(attrs, Atom.to_string(key))
      value -> value
    end
  end
end

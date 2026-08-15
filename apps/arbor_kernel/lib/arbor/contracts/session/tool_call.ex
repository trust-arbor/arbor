defmodule Arbor.Contracts.Session.ToolCall do
  @moduledoc """
  TypedStruct for a single tool call within a session turn.

  Captures the full lifecycle of a tool invocation: from authorization through
  execution to result. Tracks capability URI for security audit trails,
  timing for performance monitoring, and error details for diagnostics.

  ## Lifecycle

  1. Tool call created with `id`, `name`, `arguments`
  2. Authorized — `capability_uri` and `authorized_at` set
  3. Executed — `result`, `executed_at`, `duration_ms` set
  4. On failure — `error` set instead of `result`

  ## Usage

      {:ok, tc} = ToolCall.new(id: "tc_1", name: "shell.exec", arguments: %{cmd: "ls"})

      ToolCall.succeeded?(tc)  # => false (no result yet)
      ToolCall.failed?(tc)     # => false (no error yet)

  ## JSON Encoding

  The `:result` field is excluded from JSON encoding since tool results
  may contain arbitrary terms that are not JSON-serializable.
  """

  use TypedStruct

  alias Arbor.Identifiers

  @derive {Jason.Encoder, except: [:result]}
  typedstruct do
    @typedoc "A single tool call within a session turn"

    field(:id, String.t(), enforce: true)
    field(:name, String.t(), enforce: true)
    field(:arguments, map(), default: %{})
    field(:result, term() | nil)
    field(:capability_uri, String.t() | nil)
    field(:authorized_at, DateTime.t() | nil)
    field(:executed_at, DateTime.t() | nil)
    field(:duration_ms, non_neg_integer() | nil)
    field(:error, String.t() | nil)
    field(:metadata, map(), default: %{})
  end

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new tool call struct.

  Accepts a keyword list or map. The `id` and `name` fields are required.
  If `id` is not provided, one is auto-generated with a `"tc_"` prefix.

  ## Required Fields

  - `:name` — Tool name (e.g., `"shell.exec"`, `"file.read"`)

  ## Optional Fields

  - `:id` — Override the auto-generated tool call ID
  - `:arguments` — Tool arguments map (default: `%{}`)
  - `:result` — Tool execution result
  - `:capability_uri` — Capability URI that authorized this call
  - `:authorized_at` — When authorization was granted
  - `:executed_at` — When execution completed
  - `:duration_ms` — Execution duration in milliseconds
  - `:error` — Error message if the call failed
  - `:metadata` — Arbitrary metadata (default: `%{}`)

  ## Examples

      {:ok, tc} = ToolCall.new(name: "shell.exec", arguments: %{cmd: "ls"})

      {:ok, tc} = ToolCall.new(
        id: "tc_custom",
        name: "file.read",
        arguments: %{path: "/tmp/data.txt"},
        capability_uri: "urn:arbor:capability:file:read"
      )

      {:error, {:missing_required, :name}} = ToolCall.new(%{})

      {:error, {:invalid_arguments, "not a map"}} = ToolCall.new(name: "x", arguments: "not a map")
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_required_string(attrs, :name),
         :ok <- validate_optional_string(attrs, :id),
         :ok <- validate_arguments(get_attr(attrs, :arguments)),
         :ok <- validate_optional_string(attrs, :capability_uri),
         :ok <- validate_optional_datetime(attrs, :authorized_at),
         :ok <- validate_optional_datetime(attrs, :executed_at),
         :ok <- validate_optional_non_neg_integer(attrs, :duration_ms),
         :ok <- validate_optional_string(attrs, :error),
         :ok <- validate_optional_map(attrs, :metadata) do
      tool_call = %__MODULE__{
        id: get_attr(attrs, :id) || Identifiers.generate_id("tc_"),
        name: get_attr(attrs, :name),
        arguments: get_attr(attrs, :arguments) || %{},
        result: get_attr(attrs, :result),
        capability_uri: get_attr(attrs, :capability_uri),
        authorized_at: get_attr(attrs, :authorized_at),
        executed_at: get_attr(attrs, :executed_at),
        duration_ms: get_attr(attrs, :duration_ms),
        error: get_attr(attrs, :error),
        metadata: get_attr(attrs, :metadata) || %{}
      }

      {:ok, tool_call}
    end
  end

  # ============================================================================
  # Queries
  # ============================================================================

  @doc """
  Returns `true` if the tool call completed successfully.

  A tool call is considered successful when it has a non-nil `result`
  and no `error`.

  ## Examples

      {:ok, tc} = ToolCall.new(name: "shell.exec")
      ToolCall.succeeded?(tc)  # => false

      tc = %{tc | result: "file listing", executed_at: DateTime.utc_now()}
      ToolCall.succeeded?(tc)  # => true

      tc = %{tc | error: "permission denied"}
      ToolCall.succeeded?(tc)  # => false (error takes precedence)
  """
  @spec succeeded?(t()) :: boolean()
  def succeeded?(%__MODULE__{error: error}) when not is_nil(error), do: false
  def succeeded?(%__MODULE__{result: result}) when not is_nil(result), do: true
  def succeeded?(%__MODULE__{}), do: false

  @doc """
  Returns `true` if the tool call failed.

  A tool call is considered failed when it has a non-nil `error` field.

  ## Examples

      {:ok, tc} = ToolCall.new(name: "shell.exec")
      ToolCall.failed?(tc)  # => false

      tc = %{tc | error: "command not found"}
      ToolCall.failed?(tc)  # => true
  """
  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{error: error}) when not is_nil(error), do: true
  def failed?(%__MODULE__{}), do: false

  # ============================================================================
  # Private — Validation
  # ============================================================================

  defp validate_required_string(attrs, key) do
    case get_attr(attrs, key) do
      nil -> {:error, {:missing_required, key}}
      val when is_binary(val) and byte_size(val) > 0 -> :ok
      "" -> {:error, {:missing_required, key}}
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_optional_string(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_binary(val) -> :ok
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_arguments(nil), do: :ok
  defp validate_arguments(args) when is_map(args), do: :ok
  defp validate_arguments(invalid), do: {:error, {:invalid_arguments, invalid}}

  defp validate_optional_datetime(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      %DateTime{} -> :ok
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_optional_non_neg_integer(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_integer(val) and val >= 0 -> :ok
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_optional_map(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_map(val) -> :ok
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
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

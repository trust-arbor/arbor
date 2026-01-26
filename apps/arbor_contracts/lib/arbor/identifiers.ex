defmodule Arbor.Identifiers do
  @moduledoc """
  Provides functions for creating, validating, and parsing system identifiers.

  This module contains the executable logic for working with the types defined
  in `Arbor.Types`. This includes generating unique IDs, validating URI formats,
  and parsing structured identifiers.

  ## ID Format

  All IDs follow the pattern: `{prefix}_{32_char_hex}`

  ## URI Format

  ### Resource URIs
  Format: `arbor://{resource_type}/{operation}/{path}`
  Example: `arbor://fs/read/home/user/documents`

  ### Agent URIs
  Format: `arbor://agent/{agent_id}`
  Example: `arbor://agent/agent_abc123def456`
  """

  alias Arbor.Types

  # URI format validations
  @resource_uri_regex ~r/^arbor:\/\/[a-z]+\/[a-z]+\/.+$/
  @agent_uri_regex ~r/^arbor:\/\/agent\/[a-zA-Z0-9_-]+$/

  # ID format specifications
  @agent_id_prefix "agent_"
  @session_id_prefix "session_"
  @capability_id_prefix "cap_"
  @trace_id_prefix "trace_"
  @execution_id_prefix "exec_"

  @doc """
  Validate a resource URI format.

  Resource URIs must follow the pattern: `arbor://{type}/{operation}/{path}`

  ## Examples

      iex> Arbor.Identifiers.valid_resource_uri?("arbor://fs/read/home/user")
      true

      iex> Arbor.Identifiers.valid_resource_uri?("invalid-uri")
      false
  """
  @spec valid_resource_uri?(term()) :: boolean()
  def valid_resource_uri?(uri) when is_binary(uri) do
    Regex.match?(@resource_uri_regex, uri)
  end

  def valid_resource_uri?(_), do: false

  @doc """
  Validate an agent URI format.

  Agent URIs must follow the pattern: `arbor://agent/{agent_id}`

  ## Examples

      iex> Arbor.Identifiers.valid_agent_uri?("arbor://agent/agent_abc123")
      true

      iex> Arbor.Identifiers.valid_agent_uri?("arbor://invalid/format")
      false
  """
  @spec valid_agent_uri?(term()) :: boolean()
  def valid_agent_uri?(uri) when is_binary(uri) do
    Regex.match?(@agent_uri_regex, uri)
  end

  def valid_agent_uri?(_), do: false

  @doc """
  Generate a unique ID with the given prefix.

  IDs are generated using cryptographically secure random bytes
  encoded as lowercase hexadecimal.

  ## Examples

      iex> id = Arbor.Identifiers.generate_id("test_")
      iex> String.starts_with?(id, "test_")
      true
  """
  @spec generate_id(String.t()) :: String.t()
  def generate_id(prefix) when is_binary(prefix) do
    random_part = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    prefix <> random_part
  end

  @doc """
  Generate a unique agent ID.
  """
  @spec generate_agent_id() :: Types.agent_id()
  def generate_agent_id, do: generate_id(@agent_id_prefix)

  @doc """
  Generate a unique session ID.
  """
  @spec generate_session_id() :: Types.session_id()
  def generate_session_id, do: generate_id(@session_id_prefix)

  @doc """
  Generate a unique capability ID.
  """
  @spec generate_capability_id() :: Types.capability_id()
  def generate_capability_id, do: generate_id(@capability_id_prefix)

  @doc """
  Generate a unique trace ID for distributed tracing.
  """
  @spec generate_trace_id() :: Types.trace_id()
  def generate_trace_id, do: generate_id(@trace_id_prefix)

  @doc """
  Generate a unique execution ID.
  """
  @spec generate_execution_id() :: Types.execution_id()
  def generate_execution_id, do: generate_id(@execution_id_prefix)

  @doc """
  Convert an agent ID to an agent URI.

  ## Examples

      iex> Arbor.Identifiers.agent_id_to_uri("agent_abc123")
      "arbor://agent/agent_abc123"
  """
  @spec agent_id_to_uri(Types.agent_id()) :: Types.agent_uri()
  def agent_id_to_uri(agent_id) when is_binary(agent_id) do
    "arbor://agent/" <> agent_id
  end

  @doc """
  Extract agent ID from an agent URI.

  ## Examples

      iex> Arbor.Identifiers.agent_uri_to_id("arbor://agent/agent_abc123")
      {:ok, "agent_abc123"}

      iex> Arbor.Identifiers.agent_uri_to_id("invalid-uri")
      {:error, :invalid_agent_uri}
  """
  @spec agent_uri_to_id(Types.agent_uri()) ::
          {:ok, Types.agent_id()} | {:error, :invalid_agent_uri}
  def agent_uri_to_id("arbor://agent/" <> agent_id) when is_binary(agent_id) do
    if String.starts_with?(agent_id, @agent_id_prefix) do
      {:ok, agent_id}
    else
      {:error, :invalid_agent_uri}
    end
  end

  def agent_uri_to_id(_), do: {:error, :invalid_agent_uri}

  @doc """
  Parse a resource URI into its components.

  ## Examples

      iex> Arbor.Identifiers.parse_resource_uri("arbor://fs/read/home/user/docs")
      {:ok, %{type: "fs", operation: "read", path: "home/user/docs"}}

      iex> Arbor.Identifiers.parse_resource_uri("invalid-uri")
      {:error, :invalid_resource_uri}
  """
  @spec parse_resource_uri(Types.resource_uri()) ::
          {:ok, map()} | {:error, :invalid_resource_uri}
  def parse_resource_uri("arbor://" <> rest) when is_binary(rest) do
    case String.split(rest, "/", parts: 3) do
      [type, operation, path] when type != "" and operation != "" and path != "" ->
        {:ok, %{type: type, operation: operation, path: path}}

      _ ->
        {:error, :invalid_resource_uri}
    end
  end

  def parse_resource_uri(_), do: {:error, :invalid_resource_uri}

  @doc """
  Build a resource URI from components.

  ## Examples

      iex> Arbor.Identifiers.build_resource_uri("fs", "read", "home/user/docs")
      "arbor://fs/read/home/user/docs"
  """
  @spec build_resource_uri(String.t(), String.t(), String.t()) :: Types.resource_uri()
  def build_resource_uri(type, operation, path)
      when is_binary(type) and is_binary(operation) and is_binary(path) do
    "arbor://#{type}/#{operation}/#{path}"
  end

  @doc """
  Check if an ID has the correct format for its type.

  ## Examples

      iex> Arbor.Identifiers.valid_id?("agent_abc123def456", :agent)
      true

      iex> Arbor.Identifiers.valid_id?("invalid", :agent)
      false
  """
  @spec valid_id?(String.t(), atom()) :: boolean()
  def valid_id?(id, type) when is_binary(id) do
    prefix =
      case type do
        :agent -> @agent_id_prefix
        :session -> @session_id_prefix
        :capability -> @capability_id_prefix
        :trace -> @trace_id_prefix
        :execution -> @execution_id_prefix
        _ -> nil
      end

    if prefix do
      String.starts_with?(id, prefix) and String.length(id) == String.length(prefix) + 32
    else
      false
    end
  end

  def valid_id?(_, _), do: false
end

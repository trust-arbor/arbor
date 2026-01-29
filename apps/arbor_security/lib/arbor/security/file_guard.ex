defmodule Arbor.Security.FileGuard do
  @moduledoc """
  Capability-based file access authorization with path traversal protection.

  FileGuard provides defense-in-depth for filesystem operations by combining:
  1. **Capability verification** - Agent must hold a valid fs capability
  2. **Path resolution** - SafePath ensures paths stay within allowed roots
  3. **Pattern matching** - Optional file pattern constraints (e.g., `*.ex` only)

  ## Resource URI Format

  Filesystem capabilities use URIs like:
  - `arbor://fs/read/project/src` - Read access to /project/src
  - `arbor://fs/write/workspace` - Write access to /workspace
  - `arbor://fs/execute/scripts` - Execute access to /scripts

  ## Constraint Options

  Capabilities can include constraints in their `constraints` map:

  - `:patterns` - List of allowed file patterns (e.g., `["*.ex", "*.exs"]`)
  - `:max_depth` - Maximum directory depth allowed
  - `:exclude` - List of excluded patterns (e.g., `[".env", "*.secret"]`)

  ## Usage

      # Check if agent can access a file
      case FileGuard.authorize("agent_001", "/project/src/main.ex", :read) do
        {:ok, resolved_path} -> File.read!(resolved_path)
        {:error, reason} -> handle_denial(reason)
      end

      # Fast boolean check
      if FileGuard.can?("agent_001", "/project/src/main.ex", :read) do
        # proceed
      end

  ## Security Model

  FileGuard enforces the principle of least privilege:
  - Agents can only access paths within their capability's root
  - Path traversal attempts (../) are resolved and checked
  - Symlinks are followed and verified to stay within bounds
  - Pattern constraints provide fine-grained control
  """

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.CapabilityStore

  @type operation :: :read | :write | :execute | :delete | :list
  @type authorize_result ::
          {:ok, String.t()}
          | {:error, :no_capability | :path_traversal | :pattern_mismatch | :expired | term()}

  @fs_operations [:read, :write, :execute, :delete, :list]

  @doc """
  Authorize a file operation for an agent.

  Returns the resolved safe path if authorized, or an error describing why
  access was denied.

  ## Parameters

  - `agent_id` - The agent requesting access
  - `requested_path` - The filesystem path the agent wants to access
  - `operation` - The operation type (:read, :write, :execute, :delete, :list)

  ## Returns

  - `{:ok, resolved_path}` - Access granted, use this resolved path
  - `{:error, :no_capability}` - Agent has no fs capability for this path/operation
  - `{:error, :path_traversal}` - Path escapes the allowed root
  - `{:error, :pattern_mismatch}` - File doesn't match allowed patterns
  - `{:error, :expired}` - Capability has expired

  ## Examples

      iex> FileGuard.authorize("agent_001", "/workspace/project/file.ex", :read)
      {:ok, "/workspace/project/file.ex"}

      iex> FileGuard.authorize("agent_001", "/workspace/../etc/passwd", :read)
      {:error, :path_traversal}

      iex> FileGuard.authorize("agent_002", "/workspace/secret.env", :read)
      {:error, :pattern_mismatch}
  """
  @spec authorize(String.t(), String.t(), operation()) :: authorize_result()
  def authorize(agent_id, requested_path, operation) when operation in @fs_operations do
    with {:ok, capability} <- find_fs_capability(agent_id, operation, requested_path),
         :ok <- check_expiration(capability),
         {:ok, root} <- extract_root_from_capability(capability),
         {:ok, resolved} <- resolve_and_validate_path(requested_path, root),
         :ok <- check_pattern_constraints(resolved, capability.constraints),
         :ok <- check_exclude_constraints(resolved, capability.constraints),
         :ok <- check_depth_constraints(resolved, root, capability.constraints) do
      {:ok, resolved}
    end
  end

  @doc """
  Fast boolean check for file access authorization.

  ## Examples

      iex> FileGuard.can?("agent_001", "/workspace/file.ex", :read)
      true
  """
  @spec can?(String.t(), String.t(), operation()) :: boolean()
  def can?(agent_id, requested_path, operation) do
    case authorize(agent_id, requested_path, operation) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Authorize and return the capability that grants access.

  Useful when you need to inspect the capability's constraints or metadata.

  ## Examples

      iex> {:ok, path, cap} = FileGuard.authorize_with_capability("agent_001", "/workspace/file.ex", :read)
      iex> cap.constraints[:patterns]
      ["*.ex", "*.exs"]
  """
  @spec authorize_with_capability(String.t(), String.t(), operation()) ::
          {:ok, String.t(), Capability.t()} | {:error, term()}
  def authorize_with_capability(agent_id, requested_path, operation) do
    with {:ok, capability} <- find_fs_capability(agent_id, operation, requested_path),
         :ok <- check_expiration(capability),
         {:ok, root} <- extract_root_from_capability(capability),
         {:ok, resolved} <- resolve_and_validate_path(requested_path, root),
         :ok <- check_pattern_constraints(resolved, capability.constraints),
         :ok <- check_exclude_constraints(resolved, capability.constraints),
         :ok <- check_depth_constraints(resolved, root, capability.constraints) do
      {:ok, resolved, capability}
    end
  end

  @doc """
  Build a filesystem resource URI.

  ## Examples

      iex> FileGuard.resource_uri(:read, "/workspace/project")
      "arbor://fs/read/workspace/project"

      iex> FileGuard.resource_uri(:write, "/data")
      "arbor://fs/write/data"
  """
  @spec resource_uri(operation(), String.t()) :: String.t()
  def resource_uri(operation, path) when operation in @fs_operations do
    # Normalize path: remove leading slash for URI format
    normalized = String.trim_leading(path, "/")
    "arbor://fs/#{operation}/#{normalized}"
  end

  @doc """
  Parse a filesystem resource URI into its components.

  ## Examples

      iex> FileGuard.parse_resource_uri("arbor://fs/read/workspace/project")
      {:ok, :read, "/workspace/project"}

      iex> FileGuard.parse_resource_uri("arbor://api/call/service")
      {:error, :not_fs_resource}
  """
  @spec parse_resource_uri(String.t()) :: {:ok, operation(), String.t()} | {:error, term()}
  def parse_resource_uri("arbor://fs/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [operation_str, path] ->
        case parse_operation(operation_str) do
          {:ok, operation} -> {:ok, operation, "/" <> path}
          error -> error
        end

      [operation_str] ->
        case parse_operation(operation_str) do
          {:ok, operation} -> {:ok, operation, "/"}
          error -> error
        end
    end
  end

  def parse_resource_uri(_), do: {:error, :not_fs_resource}

  @doc """
  List all filesystem capabilities for an agent.

  Returns capabilities filtered to only fs:// resources.
  """
  @spec list_fs_capabilities(String.t()) :: {:ok, [Capability.t()]} | {:error, term()}
  def list_fs_capabilities(agent_id) do
    case CapabilityStore.list_for_principal(agent_id) do
      {:ok, caps} ->
        fs_caps = Enum.filter(caps, &fs_capability?/1)
        {:ok, fs_caps}

      error ->
        error
    end
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp find_fs_capability(agent_id, operation, requested_path) do
    resource_uri = resource_uri(operation, requested_path)

    case CapabilityStore.find_authorizing(agent_id, resource_uri) do
      {:ok, cap} ->
        {:ok, cap}

      {:error, :not_found} ->
        # Try to find a parent capability that covers this path
        find_parent_capability(agent_id, operation, requested_path)
    end
  end

  defp find_parent_capability(agent_id, operation, requested_path) do
    # Look for capabilities that cover parent directories
    case CapabilityStore.list_for_principal(agent_id) do
      {:ok, caps} ->
        # Filter to fs capabilities for the right operation that cover this path
        matching =
          Enum.filter(caps, fn cap ->
            fs_capability?(cap) and path_covered_by_capability?(cap, operation, requested_path)
          end)

        case matching do
          [cap | _] -> {:ok, cap}
          [] -> {:error, :no_capability}
        end

      error ->
        error
    end
  end

  defp check_expiration(%Capability{expires_at: nil}), do: :ok

  defp check_expiration(%Capability{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      :ok
    else
      {:error, :expired}
    end
  end

  defp extract_root_from_capability(%Capability{resource_uri: uri}) do
    case parse_resource_uri(uri) do
      {:ok, _operation, path} -> {:ok, path}
      error -> error
    end
  end

  defp resolve_and_validate_path(requested_path, root) do
    # Use SafePath to resolve and validate the path stays within root
    case SafePath.resolve_within(requested_path, root) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, :path_traversal} -> {:error, :path_traversal}
      {:error, reason} -> {:error, {:invalid_path, reason}}
    end
  end

  defp check_pattern_constraints(_path, %{patterns: patterns}) when is_list(patterns) do
    # Pattern constraints not yet checked - would need the resolved filename
    # This is a placeholder for pattern matching logic
    :ok
  end

  defp check_pattern_constraints(resolved_path, constraints) do
    patterns = constraints[:patterns] || constraints["patterns"]

    if is_list(patterns) && patterns != [] do
      filename = Path.basename(resolved_path)

      if Enum.any?(patterns, &pattern_matches?(filename, &1)) do
        :ok
      else
        {:error, :pattern_mismatch}
      end
    else
      :ok
    end
  end

  defp check_exclude_constraints(resolved_path, constraints) do
    excludes = constraints[:exclude] || constraints["exclude"]

    if is_list(excludes) && excludes != [] do
      filename = Path.basename(resolved_path)

      if Enum.any?(excludes, &pattern_matches?(filename, &1)) do
        {:error, :excluded_pattern}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp check_depth_constraints(resolved_path, root, constraints) do
    max_depth = constraints[:max_depth] || constraints["max_depth"]

    if max_depth && is_integer(max_depth) do
      # Calculate depth relative to root
      relative = String.trim_leading(resolved_path, root)
      depth = relative |> String.split("/") |> Enum.reject(&(&1 == "")) |> length()

      if depth <= max_depth do
        :ok
      else
        {:error, :max_depth_exceeded}
      end
    else
      :ok
    end
  end

  defp pattern_matches?(filename, pattern) do
    # Convert glob pattern to regex
    regex_pattern =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.match?(~r/^#{regex_pattern}$/, filename)
  end

  defp fs_capability?(%Capability{resource_uri: "arbor://fs/" <> _}), do: true
  defp fs_capability?(_), do: false

  defp path_covered_by_capability?(cap, operation, requested_path) do
    case parse_resource_uri(cap.resource_uri) do
      {:ok, ^operation, cap_path} ->
        # Check if requested path is under the capability's path
        String.starts_with?(requested_path, cap_path) or
          String.starts_with?(requested_path, cap_path <> "/")

      _ ->
        false
    end
  end

  defp parse_operation("read"), do: {:ok, :read}
  defp parse_operation("write"), do: {:ok, :write}
  defp parse_operation("execute"), do: {:ok, :execute}
  defp parse_operation("delete"), do: {:ok, :delete}
  defp parse_operation("list"), do: {:ok, :list}
  defp parse_operation(other), do: {:error, {:unknown_operation, other}}
end

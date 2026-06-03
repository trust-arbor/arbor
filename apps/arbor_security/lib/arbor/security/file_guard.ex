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
         :ok <- check_expiration(capability) do
      if wildcard_capability?(capability) do
        # Wildcard fs capability (arbor://fs/**) — grants all operations on all paths.
        # Skip root-based path validation since there is no root constraint.
        # Still resolve to absolute path to prevent relative path tricks.
        {:ok, Path.expand(requested_path)}
      else
        with {:ok, root} <- extract_root_from_capability(capability),
             {:ok, resolved} <- resolve_and_validate_path(requested_path, root),
             :ok <- check_pattern_constraints(resolved, capability.constraints),
             :ok <- check_exclude_constraints(resolved, capability.constraints),
             :ok <- check_depth_constraints(resolved, root, capability.constraints) do
          {:ok, resolved}
        end
      end
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
         :ok <- check_expiration(capability) do
      if wildcard_capability?(capability) do
        {:ok, Path.expand(requested_path), capability}
      else
        with {:ok, root} <- extract_root_from_capability(capability),
             {:ok, resolved} <- resolve_and_validate_path(requested_path, root),
             :ok <- check_pattern_constraints(resolved, capability.constraints),
             :ok <- check_exclude_constraints(resolved, capability.constraints),
             :ok <- check_depth_constraints(resolved, root, capability.constraints) do
          {:ok, resolved, capability}
        end
      end
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
  Defense-in-depth path normalization for fs:// URIs that have already
  been authorized by the URI matcher.

  This is the "implicit FileGuard" path: `Arbor.Security.authorize/4`
  invokes this for every `arbor://fs/<op>/<path>` URI after the
  capability matcher accepts. The cap re-lookup that the public
  `authorize/3` does is skipped — we already have the matching
  capability from the matcher.

  Adds two defenses beyond the URI matcher's prefix check:

    1. **Symlink-escape detection.** `SafePath.resolve_real/1` follows
       symlinks. A file at the authorized URI path that points outside
       the cap's root yields `{:error, :symlink_escape}`.
    2. **Wildcard-aware root extraction.** Caps like
       `arbor://fs/read/workspace/**` are handled by stripping the
       wildcard suffix to recover the directory root before the
       normalization runs.

  Returns `{:ok, resolved_path}` or `{:error, reason}`. Callers that
  don't care about the resolved path can ignore it.

  Returns `:not_applicable` when the URI isn't an fs URI or the cap
  has no recoverable root — the caller should fall through to whatever
  default behavior it had before this check.
  """
  @spec normalize_uri_path_for_capability(String.t(), Capability.t()) ::
          {:ok, String.t()} | {:error, term()} | :not_applicable
  def normalize_uri_path_for_capability(resource_uri, %Capability{} = cap) do
    with {:ok, _operation, requested_path} <- parse_resource_uri(resource_uri),
         {:ok, root} <- extract_root_for_normalization(cap.resource_uri) do
      safe_normalize_uri_path(requested_path, root)
    else
      # Not an fs URI, or the cap doesn't have a recoverable filesystem
      # root (e.g. wildcard cap with no path part). Skip path
      # normalization; the URI matcher's check stands.
      _ -> :not_applicable
    end
  end

  # Lighter-weight normalization than resolve_and_validate_path/2.
  # Differences:
  #   * For non-existent files (legitimate at URI-authorize time — the
  #     caller may be about to write the file) we trust the SafePath
  #     string check rather than walking parent directories. Walking
  #     parents produces a false positive when the URI's path equals
  #     the cap's root (the parent of the root is by definition
  #     outside the root).
  #   * We don't try to identify whether the target is a symlink before
  #     resolving. Instead we ALWAYS call resolve_real and check
  #     containment — that catches POSIX symlinks, Windows NTFS
  #     symbolic links, NTFS junctions, OneDrive placeholders, and any
  #     other reparse-point variant uniformly. Avoiding the file-type
  #     identification step makes the check cross-platform correct,
  #     since Erlang's File.Stat mapping varies across Windows reparse
  #     point types but resolve_real follows whatever the OS considers
  #     a link.
  defp safe_normalize_uri_path(requested_path, root) do
    with {:ok, normalized} <- SafePath.resolve_within(requested_path, root) do
      case SafePath.resolve_real(normalized) do
        {:ok, real} ->
          # The OS resolved the path. If the real target stays in the
          # cap's root, fine. Otherwise it's a link / junction / mount
          # escaping the cap's scope.
          case SafePath.resolve_within(real, root) do
            {:ok, _} -> {:ok, normalized}
            {:error, _} -> {:error, :symlink_escape}
          end

        {:error, :not_found} ->
          # Target doesn't exist yet — no escape possible because
          # there's nothing to follow. The caller may be about to
          # create the file; the eventual I/O system call will fail
          # with :enoent if that's not the case. The string-normalized
          # path stays within root (resolve_within already verified).
          {:ok, normalized}

        {:error, _} ->
          # Other resolution failure (permission, broken link target,
          # etc.). Trust the string check; downstream I/O will see the
          # real error.
          {:ok, normalized}
      end
    end
  end

  # Recover a filesystem root from a capability URI for path normalization.
  # Handles intermediate wildcards (the existing `extract_root_from_capability/1`
  # doesn't — it would return "/workspace/**" as the root, which SafePath
  # can't bound-check).
  defp extract_root_for_normalization("arbor://fs/**"), do: {:ok, "/"}

  defp extract_root_for_normalization(uri) do
    # Strip trailing wildcards before parsing — "/workspace/**" → "/workspace",
    # "/data/*" → "/data". The matcher already validated that the URI
    # structurally covers the request; we just need the directory root for
    # SafePath to bound-check against.
    cleaned =
      uri
      |> String.trim_trailing("/**")
      |> String.trim_trailing("/*")
      |> String.trim_trailing("/")

    case parse_resource_uri(cleaned) do
      {:ok, _operation, path} when path != "/" -> {:ok, path}
      _ -> :not_applicable
    end
  end

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

  defp extract_root_from_capability(%Capability{resource_uri: "arbor://fs/**"}), do: {:ok, "/"}

  defp extract_root_from_capability(%Capability{resource_uri: uri}) do
    case parse_resource_uri(uri) do
      {:ok, _operation, path} -> {:ok, path}
      error -> error
    end
  end

  defp resolve_and_validate_path(requested_path, root) do
    # H2: pre-fix, FileGuard relied only on SafePath.resolve_within/2 — string
    # normalization that does NOT follow symlinks. A symlink inside the
    # authorized root could point outside the root, and authorization would
    # pass on the normalized path while the actual I/O happened against the
    # symlink target. Now we first normalize, then resolve the real path
    # (or its parent for non-existent targets) and verify it's still within
    # the authorized root.
    with {:ok, normalized} <- normalize_or_traversal(requested_path, root),
         {:ok, real} <- real_path_within(normalized, root) do
      {:ok, real}
    end
  end

  defp normalize_or_traversal(requested_path, root) do
    case SafePath.resolve_within(requested_path, root) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, :path_traversal} -> {:error, :path_traversal}
      {:error, reason} -> {:error, {:invalid_path, reason}}
    end
  end

  defp real_path_within(normalized, root) do
    case SafePath.resolve_real(normalized) do
      {:ok, real} ->
        check_real_within(real, root, normalized)

      {:error, :not_found} ->
        # Target doesn't exist yet (legitimate for write/create). Resolve the
        # parent's real path instead and verify it's within root — that
        # prevents a symlink in the parent chain from pointing the future
        # file at an outside path.
        parent = Path.dirname(normalized)

        case SafePath.resolve_real(parent) do
          {:ok, real_parent} ->
            check_real_within(real_parent, root, normalized)

          {:error, :not_found} ->
            # Whole prefix is missing; the normalized path is the best we
            # can do. Fall back to it (no symlink escape possible if no
            # symlinks exist on the path).
            {:ok, normalized}
        end
    end
  end

  defp check_real_within(real, root, fallback) do
    case SafePath.resolve_within(real, root) do
      {:ok, _} -> {:ok, fallback}
      {:error, :path_traversal} -> {:error, :symlink_escape}
      {:error, reason} -> {:error, {:invalid_path, reason}}
    end
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

  defp wildcard_capability?(%Capability{resource_uri: "arbor://fs/**"}), do: true
  defp wildcard_capability?(_), do: false

  defp path_covered_by_capability?(
         %Capability{resource_uri: "arbor://fs/**"},
         _operation,
         _requested_path
       ) do
    # Wildcard capability grants all operations on all paths
    true
  end

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

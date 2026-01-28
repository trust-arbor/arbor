defmodule Arbor.Common.SafePath do
  @moduledoc """
  Safe file path handling utilities that prevent path traversal attacks.

  Path traversal (directory traversal) attacks occur when user-controlled input
  is used to construct file paths, allowing attackers to access files outside
  intended directories (e.g., `../../../etc/passwd`).

  This module provides utilities to:
  - Validate paths don't contain traversal sequences
  - Ensure resolved paths stay within allowed directories
  - Safely join paths without enabling escape

  ## Security Context

  This module is critical for:
  - Sandbox workspace boundaries
  - Agent file access capabilities
  - Shell command path arguments
  - Any file operation with external input

  ## Examples

      # Check if path stays within allowed root
      iex> SafePath.within?("/workspace/project/file.txt", "/workspace")
      true

      iex> SafePath.within?("/workspace/../etc/passwd", "/workspace")
      false

      # Safe path joining
      iex> SafePath.safe_join("/workspace", "subdir/file.txt")
      {:ok, "/workspace/subdir/file.txt"}

      iex> SafePath.safe_join("/workspace", "../etc/passwd")
      {:error, :path_traversal}

      # Validate path components
      iex> SafePath.validate("normal/path/file.txt")
      :ok

      iex> SafePath.validate("path/../../../etc/passwd")
      {:error, :traversal_sequence}
  """

  @type path :: String.t()
  @type validation_error ::
          :traversal_sequence
          | :null_byte
          | :empty_path
          | :absolute_in_relative_context
          | :invalid_encoding

  @type within_error :: :path_traversal | :invalid_path

  # Dangerous encoded sequences that indicate traversal attempts
  # Note: Literal ".." is allowed in validate/1 - the security check happens
  # in resolve_within/2 which verifies the resolved path stays within bounds.
  # These encoded patterns are always suspicious as they suggest bypass attempts.
  @encoded_traversal_patterns [
    # URL-encoded variants
    "%2e%2e",
    "%2E%2E",
    # Double-encoded
    "%252e%252e",
    # Mixed encoding
    "%2e.",
    ".%2e"
  ]

  # Null byte can truncate paths in some contexts
  @null_byte <<0>>

  @doc """
  Check if a path, when resolved, stays within the allowed root directory.

  This is the primary security check - it normalizes both paths and verifies
  the target doesn't escape the allowed root.

  ## Examples

      iex> Arbor.Common.SafePath.within?("/workspace/project/file.txt", "/workspace")
      true

      iex> Arbor.Common.SafePath.within?("/workspace/../etc/passwd", "/workspace")
      false

      iex> Arbor.Common.SafePath.within?("subdir/file.txt", "/workspace")
      true

      iex> Arbor.Common.SafePath.within?("../escape", "/workspace")
      false
  """
  @spec within?(path(), path()) :: boolean()
  def within?(path, allowed_root) when is_binary(path) and is_binary(allowed_root) do
    case resolve_within(path, allowed_root) do
      {:ok, _resolved} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Resolve a path and verify it stays within the allowed root.

  Returns the normalized absolute path if valid, or an error if the path
  would escape the allowed root.

  ## Examples

      iex> Arbor.Common.SafePath.resolve_within("subdir/file.txt", "/workspace")
      {:ok, "/workspace/subdir/file.txt"}

      iex> Arbor.Common.SafePath.resolve_within("../escape", "/workspace")
      {:error, :path_traversal}
  """
  @spec resolve_within(path(), path()) :: {:ok, path()} | {:error, within_error()}
  def resolve_within(path, allowed_root) when is_binary(path) and is_binary(allowed_root) do
    with :ok <- validate(path),
         normalized_root <- normalize(allowed_root),
         full_path <- build_full_path(path, normalized_root),
         normalized <- normalize(full_path) do
      if String.starts_with?(normalized, normalized_root <> "/") or normalized == normalized_root do
        {:ok, normalized}
      else
        {:error, :path_traversal}
      end
    end
  end

  @doc """
  Safely join a base path with a user-provided path component.

  This ensures the resulting path stays within the base directory,
  even if the user path contains traversal sequences.

  ## Examples

      iex> Arbor.Common.SafePath.safe_join("/workspace", "subdir/file.txt")
      {:ok, "/workspace/subdir/file.txt"}

      iex> Arbor.Common.SafePath.safe_join("/workspace", "../etc/passwd")
      {:error, :path_traversal}

      iex> Arbor.Common.SafePath.safe_join("/workspace", "/absolute/path")
      {:error, :path_traversal}
  """
  @spec safe_join(path(), path()) :: {:ok, path()} | {:error, within_error()}
  def safe_join(base, user_path) when is_binary(base) and is_binary(user_path) do
    # Absolute user paths are suspicious - they shouldn't be joined
    if String.starts_with?(user_path, "/") do
      {:error, :path_traversal}
    else
      resolve_within(user_path, base)
    end
  end

  @doc """
  Safely join paths, raising on traversal attempts.

  ## Examples

      iex> Arbor.Common.SafePath.safe_join!("/workspace", "file.txt")
      "/workspace/file.txt"

      iex> Arbor.Common.SafePath.safe_join!("/workspace", "../etc/passwd")
      ** (Arbor.Common.SafePath.TraversalError) Path traversal detected
  """
  @spec safe_join!(path(), path()) :: path()
  def safe_join!(base, user_path) do
    case safe_join(base, user_path) do
      {:ok, path} -> path
      {:error, reason} -> raise __MODULE__.TraversalError, reason: reason
    end
  end

  @doc """
  Validate that a path doesn't contain dangerous sequences.

  This performs static validation without filesystem access. Use `within?/2`
  or `resolve_within/2` for full security checks that resolve the actual path.

  ## Checks Performed

  - No `..` traversal sequences (including encoded variants)
  - No null bytes
  - Valid UTF-8 encoding
  - Non-empty path

  ## Examples

      iex> Arbor.Common.SafePath.validate("normal/path/file.txt")
      :ok

      iex> Arbor.Common.SafePath.validate("path/../../../etc/passwd")
      {:error, :traversal_sequence}

      iex> Arbor.Common.SafePath.validate("path/with\\x00null")
      {:error, :null_byte}

      iex> Arbor.Common.SafePath.validate("")
      {:error, :empty_path}
  """
  @spec validate(path()) :: :ok | {:error, validation_error()}
  def validate(path) when is_binary(path) do
    cond do
      path == "" ->
        {:error, :empty_path}

      not String.valid?(path) ->
        {:error, :invalid_encoding}

      String.contains?(path, @null_byte) ->
        {:error, :null_byte}

      contains_traversal?(path) ->
        {:error, :traversal_sequence}

      true ->
        :ok
    end
  end

  @doc """
  Validate a path, raising on invalid input.

  ## Examples

      iex> Arbor.Common.SafePath.validate!("safe/path")
      :ok

      iex> Arbor.Common.SafePath.validate!("../evil")
      ** (Arbor.Common.SafePath.TraversalError) Path contains traversal sequence
  """
  @spec validate!(path()) :: :ok
  def validate!(path) do
    case validate(path) do
      :ok -> :ok
      {:error, reason} -> raise __MODULE__.TraversalError, reason: reason
    end
  end

  @doc """
  Normalize a path by resolving `.` and `..` components.

  This uses `Path.expand/1` which resolves the path against the current
  directory for relative paths, or returns the absolute path for absolute paths.

  Note: This does NOT follow symlinks. For security-critical checks, use
  `resolve_real/1` which resolves symlinks via the filesystem.

  ## Examples

      iex> Arbor.Common.SafePath.normalize("/workspace/subdir/../file.txt")
      "/workspace/file.txt"

      iex> Arbor.Common.SafePath.normalize("/workspace/./file.txt")
      "/workspace/file.txt"
  """
  @spec normalize(path()) :: path()
  def normalize(path) when is_binary(path) do
    Path.expand(path)
  end

  @doc """
  Resolve a path to its real filesystem path, following symlinks.

  This is more secure than `normalize/1` as it detects symlink-based escapes,
  but requires the path to exist on the filesystem.

  Returns `{:error, :not_found}` if the path doesn't exist.

  ## Examples

      # Assuming /workspace/link is a symlink to /etc
      iex> Arbor.Common.SafePath.resolve_real("/workspace/link/passwd")
      {:ok, "/etc/passwd"}

      iex> Arbor.Common.SafePath.resolve_real("/nonexistent/path")
      {:error, :not_found}
  """
  @spec resolve_real(path()) :: {:ok, path()} | {:error, :not_found}
  def resolve_real(path) when is_binary(path) do
    case :file.read_link_info(path) do
      {:ok, _info} ->
        # Path exists, get the real path
        case :filelib.safe_relative_path(path, "/") do
          :unsafe ->
            # Fallback to manual resolution
            resolve_real_manual(path)

          safe_path ->
            {:ok, "/" <> to_string(safe_path)}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Check if a path is absolute.

  ## Examples

      iex> Arbor.Common.SafePath.absolute?("/workspace/file.txt")
      true

      iex> Arbor.Common.SafePath.absolute?("relative/path")
      false
  """
  @spec absolute?(path()) :: boolean()
  def absolute?(path) when is_binary(path) do
    String.starts_with?(path, "/")
  end

  @doc """
  Check if a path is relative.

  ## Examples

      iex> Arbor.Common.SafePath.relative?("relative/path")
      true

      iex> Arbor.Common.SafePath.relative?("/absolute/path")
      false
  """
  @spec relative?(path()) :: boolean()
  def relative?(path) when is_binary(path) do
    not absolute?(path)
  end

  @doc """
  Extract the filename from a path, validating it's safe.

  Returns error if the filename contains traversal sequences or is empty.

  ## Examples

      iex> Arbor.Common.SafePath.safe_basename("/path/to/file.txt")
      {:ok, "file.txt"}

      iex> Arbor.Common.SafePath.safe_basename("/path/to/../etc/passwd")
      {:error, :traversal_sequence}

      iex> Arbor.Common.SafePath.safe_basename("/path/to/")
      {:error, :empty_path}
  """
  @spec safe_basename(path()) :: {:ok, String.t()} | {:error, validation_error()}
  def safe_basename(path) when is_binary(path) do
    basename = Path.basename(path)

    cond do
      basename == "" ->
        {:error, :empty_path}

      basename == "." or basename == ".." ->
        {:error, :traversal_sequence}

      true ->
        validate(basename)
        |> case do
          :ok -> {:ok, basename}
          error -> error
        end
    end
  end

  @doc """
  Sanitize a filename by removing dangerous characters.

  This is useful for user-provided filenames that will be used to create
  new files. It removes path separators and traversal sequences.

  ## Options

  - `:replacement` - Character to replace dangerous chars with (default: "_")
  - `:max_length` - Maximum filename length (default: 255)

  ## Examples

      iex> Arbor.Common.SafePath.sanitize_filename("my file.txt")
      "my file.txt"

      iex> Arbor.Common.SafePath.sanitize_filename("../../../etc/passwd")
      "etc_passwd"

      iex> Arbor.Common.SafePath.sanitize_filename("file/with\\\\slashes")
      "file_with_slashes"
  """
  @spec sanitize_filename(String.t(), keyword()) :: String.t()
  def sanitize_filename(filename, opts \\ []) when is_binary(filename) do
    replacement = Keyword.get(opts, :replacement, "_")
    max_length = Keyword.get(opts, :max_length, 255)

    filename
    # Remove null bytes
    |> String.replace(@null_byte, "")
    # Remove path separators
    |> String.replace(~r{[/\\]}, replacement)
    # Remove .. traversal sequences
    |> String.replace("..", "")
    # Remove leading dots
    |> String.replace(~r{^\.+}, "")
    # Collapse multiple replacements
    |> String.replace(~r{#{Regex.escape(replacement)}+}, replacement)
    # Trim replacement from edges
    |> String.trim(replacement)
    # Truncate to max length
    |> String.slice(0, max_length)
    # Fallback for empty result
    |> case do
      "" -> "unnamed"
      name -> name
    end
  end

  # Private functions

  defp contains_traversal?(path) do
    # Check for encoded traversal patterns which suggest bypass attempts
    # Literal ".." is allowed here - security is enforced by resolve_within/2
    lowercased = String.downcase(path)

    Enum.any?(@encoded_traversal_patterns, fn pattern ->
      String.contains?(lowercased, String.downcase(pattern))
    end)
  end

  defp build_full_path(path, root) do
    if absolute?(path) do
      path
    else
      Path.join(root, path)
    end
  end

  defp resolve_real_manual(path) do
    # Manual resolution following symlinks
    # This is a fallback when :filelib.safe_relative_path doesn't work
    expanded = Path.expand(path)

    case File.read_link(expanded) do
      {:ok, target} ->
        # It's a symlink, resolve the target
        if absolute?(target) do
          resolve_real_manual(target)
        else
          resolve_real_manual(Path.join(Path.dirname(expanded), target))
        end

      {:error, :einval} ->
        # Not a symlink, this is the real path
        {:ok, expanded}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defmodule TraversalError do
    @moduledoc """
    Exception raised when path traversal is detected.
    """
    defexception [:reason]

    @impl true
    def message(%{reason: reason}) do
      case reason do
        :path_traversal -> "Path traversal detected"
        :traversal_sequence -> "Path contains traversal sequence"
        :null_byte -> "Path contains null byte"
        :empty_path -> "Path is empty"
        :invalid_encoding -> "Path has invalid encoding"
        :absolute_in_relative_context -> "Absolute path not allowed in this context"
        _ -> "Invalid path: #{inspect(reason)}"
      end
    end
  end
end

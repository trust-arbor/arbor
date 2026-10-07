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

  defmodule RootBinding do
    @moduledoc false

    @enforce_keys [:root, :device, :inode]
    defstruct [:root, :device, :inode]

    @type t :: %__MODULE__{
            root: String.t(),
            device: non_neg_integer(),
            inode: non_neg_integer()
          }
  end

  @type path :: String.t()
  @opaque root_binding :: RootBinding.t()
  @type validation_error ::
          :traversal_sequence
          | :null_byte
          | :empty_path
          | :absolute_in_relative_context
          | :invalid_encoding

  @type within_error :: :path_traversal | :invalid_path | validation_error()
  @type read_validator :: (path() -> :ok | {:error, term()})
  @type read_error ::
          within_error()
          | :not_regular
          | :path_changed
          | :descriptor_helper_unavailable
          | :descriptor_materialization_failed
          | :descriptor_protocol_error
          | :descriptor_timeout
          | File.posix()

  @test_env Application.compile_env(:arbor_kernel_runtime, :expose_test_fixtures, false)

  @descriptor_ready_timeout 5_000
  @descriptor_read_timeout 30_000
  @materialization_guard_timeout 15_000
  @native_reader_artifact Arbor.Common.SafePath.NativeReaderArtifact
  @native_reader_max_bytes 1_048_576
  @native_reader_temp_root "/tmp"
  @native_reader_temp_prefix "arbor-safe-path-reader-"

  # Native helper exit-status ABI; keep synchronized with arbor_safe_path_reader.c.
  @reader_invalid 64
  @reader_root_identity 65
  @reader_symlink 66
  @reader_not_found 67
  @reader_not_regular 68
  @reader_io 69
  @reader_protocol 70

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
         :ok <- validate(allowed_root),
         {:ok, resolved_root} <- resolve_real_allow_missing(allowed_root),
         full_path <- build_full_path_raw(path, allowed_root),
         {:ok, resolved_path} <- resolve_real_allow_missing(full_path) do
      if resolved_root == "/" or
           String.starts_with?(resolved_path, resolved_root <> "/") or
           resolved_path == resolved_root do
        {:ok, resolved_path}
      else
        {:error, :path_traversal}
      end
    else
      {:error, reason}
      when reason in [
             :path_traversal,
             :invalid_path,
             :traversal_sequence,
             :null_byte,
             :empty_path,
             :absolute_in_relative_context,
             :invalid_encoding
           ] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :invalid_path}
    end
  end

  @doc """
  Bind a canonical directory root to its current device and inode.

  Passing the returned opaque binding to a bound read makes a later root-path
  replacement fail closed instead of authorizing and opening the replacement.
  """
  @spec bind_root(path()) :: {:ok, root_binding()} | {:error, term()}
  def bind_root(allowed_root) when is_binary(allowed_root) do
    with :ok <- validate(allowed_root),
         {:ok, resolved_root} <- resolve_real(allowed_root),
         {:ok, {device, inode}} <- directory_identity(resolved_root) do
      {:ok, %RootBinding{root: resolved_root, device: device, inode: inode}}
    else
      {:error, :not_found} -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :path_changed}
    end
  rescue
    _error -> {:error, :path_changed}
  catch
    _kind, _reason -> {:error, :path_changed}
  end

  @doc "Return the canonical root path carried by an opaque root binding."
  @spec binding_root(root_binding()) :: path()
  def binding_root(%RootBinding{root: root}), do: root

  @doc """
  Read a regular file while keeping containment bound to the opened file.

  A native helper pins the canonical root directory, verifies its expected
  device and inode, and walks the canonical relative path with `openat(2)` and
  `O_NOFOLLOW`. The file is therefore opened relative to the pinned root even
  if another process replaces the root or an ancestor after validation.

  Returns the content and canonical path on success.
  """
  @spec read_within(path(), path()) ::
          {:ok, binary(), path()} | {:error, read_error()}
  def read_within(path, allowed_root)
      when is_binary(path) and is_binary(allowed_root) do
    do_read_within(path, allowed_root, fn -> :ok end, fn _opened_path -> :ok end)
  end

  @doc """
  Open a contained regular file, validate its fixed canonical path, then read.

  The validator runs only after the native helper has pinned both the root and
  final regular-file descriptors. Returning an error closes the descriptor
  without reading file data. This supports authorization constraints that must
  be checked against the exact path selection before read side effects occur.
  """
  @spec read_within_checked(path(), path(), read_validator()) ::
          {:ok, binary(), path()} | {:error, term()}
  def read_within_checked(path, allowed_root, validator)
      when is_binary(path) and is_binary(allowed_root) and is_function(validator, 1) do
    do_read_within(path, allowed_root, fn -> :ok end, validator)
  end

  @doc """
  Read within a previously bound root, validating the opened path before data.

  The binding's original device and inode are passed directly to the native
  helper. This function never re-resolves or re-stats the root to derive a new
  identity.
  """
  @spec read_within_bound_checked(path(), root_binding(), read_validator()) ::
          {:ok, binary(), path()} | {:error, term()}
  def read_within_bound_checked(path, %RootBinding{} = binding, validator)
      when is_binary(path) and is_function(validator, 1) do
    do_read_within_bound(path, binding, fn -> :ok end, validator)
  end

  @doc """
  Read one exact regular-file path without following a replacement leaf link.

  The parent is resolved and checked within `allowed_root`. A native helper
  then opens every component relative to a pinned root directory descriptor,
  with `O_NOFOLLOW` on the leaf and every ancestor. A symlink leaf or ancestor
  replacement is rejected.
  """
  @spec read_exact(path(), path()) ::
          {:ok, binary(), path()} | {:error, read_error()}
  def read_exact(path, allowed_root)
      when is_binary(path) and is_binary(allowed_root) do
    do_read_exact(path, allowed_root, fn -> :ok end, fn _opened_path -> :ok end)
  end

  @doc """
  Open an exact regular-file leaf, validate its fixed canonical path, then read.

  See `read_within_checked/3` for the descriptor and validator ordering.
  """
  @spec read_exact_checked(path(), path(), read_validator()) ::
          {:ok, binary(), path()} | {:error, term()}
  def read_exact_checked(path, allowed_root, validator)
      when is_binary(path) and is_binary(allowed_root) and is_function(validator, 1) do
    do_read_exact(path, allowed_root, fn -> :ok end, validator)
  end

  @doc """
  Read an exact leaf within a previously bound root, validating before data.

  See `read_within_bound_checked/3` for root-identity semantics.
  """
  @spec read_exact_bound_checked(path(), root_binding(), read_validator()) ::
          {:ok, binary(), path()} | {:error, term()}
  def read_exact_bound_checked(path, %RootBinding{} = binding, validator)
      when is_binary(path) and is_function(validator, 1) do
    do_read_exact_bound(path, binding, fn -> :ok end, validator)
  end

  if @test_env do
    @materialization_hook_key {__MODULE__, :native_reader_materialization_hook}

    @doc false
    def read_within_fixture(path, allowed_root, before_open)
        when is_binary(path) and is_binary(allowed_root) and is_function(before_open, 0) do
      do_read_within(path, allowed_root, before_open, fn _opened_path -> :ok end)
    end

    @doc false
    def read_exact_fixture(path, allowed_root, before_open)
        when is_binary(path) and is_binary(allowed_root) and is_function(before_open, 0) do
      do_read_exact(path, allowed_root, before_open, fn _opened_path -> :ok end)
    end

    @doc false
    def read_within_materialization_fixture(path, allowed_root, before_open, sealed_hook)
        when is_binary(path) and is_binary(allowed_root) and is_function(before_open, 0) and
               is_function(sealed_hook, 2) do
      previous = Process.get(@materialization_hook_key)
      Process.put(@materialization_hook_key, sealed_hook)

      try do
        do_read_within(path, allowed_root, before_open, fn _opened_path -> :ok end)
      after
        if is_nil(previous) do
          Process.delete(@materialization_hook_key)
        else
          Process.put(@materialization_hook_key, previous)
        end
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
    # Walk the original components in filesystem order. Expanding first would
    # collapse `link/..` before discovering that `link` points elsewhere,
    # producing a different path from the one the kernel opens.
    resolve_real_manual(path)
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

  defp build_full_path_raw(path, root) do
    if absolute?(path) do
      path
    else
      String.trim_trailing(root, "/") <> "/" <> path
    end
  end

  defp do_read_within(path, allowed_root, before_open, before_read) do
    with {:ok, binding} <- bind_root(allowed_root) do
      do_read_within_bound(path, binding, before_open, before_read)
    end
  end

  defp do_read_within_bound(
         path,
         %RootBinding{root: resolved_root, device: device, inode: inode},
         before_open,
         before_read
       ) do
    with :ok <- validate(path),
         full_path <- build_full_path_raw(path, resolved_root),
         {:ok, resolved_path} <- resolve_real(full_path),
         true <- contained_path?(resolved_path, resolved_root),
         {:ok, relative_path} <- relative_child_path(resolved_path, resolved_root) do
      read_from_pinned_root(
        resolved_root,
        {device, inode},
        relative_path,
        resolved_path,
        before_open,
        before_read
      )
    else
      false -> {:error, :path_traversal}
      {:error, :not_found} -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :path_changed}
    end
  rescue
    _error -> {:error, :path_changed}
  catch
    _kind, _reason -> {:error, :path_changed}
  end

  defp do_read_exact(path, allowed_root, before_open, before_read) do
    with {:ok, binding} <- bind_root(allowed_root) do
      do_read_exact_bound(path, binding, before_open, before_read)
    end
  end

  defp do_read_exact_bound(
         path,
         %RootBinding{root: resolved_root, device: device, inode: inode},
         before_open,
         before_read
       ) do
    with :ok <- validate(path),
         full_path <- build_full_path_raw(path, resolved_root),
         {:ok, resolved_parent} <- resolve_real(Path.dirname(full_path)),
         true <- contained_path?(resolved_parent, resolved_root),
         {:ok, leaf} <- exact_leaf(Path.basename(full_path)),
         resolved_path <- Path.join(resolved_parent, leaf),
         {:ok, relative_path} <- relative_child_path(resolved_path, resolved_root) do
      read_from_pinned_root(
        resolved_root,
        {device, inode},
        relative_path,
        resolved_path,
        before_open,
        before_read
      )
    else
      false -> {:error, :path_traversal}
      {:error, :not_found} -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :path_changed}
    end
  rescue
    _error -> {:error, :path_changed}
  catch
    _kind, _reason -> {:error, :path_changed}
  end

  defp directory_identity(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory, major_device: device, inode: inode}}
      when is_integer(device) and device >= 0 and is_integer(inode) and inode >= 0 ->
        {:ok, {device, inode}}

      {:ok, _other} ->
        {:error, :path_traversal}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exact_leaf(leaf) when leaf in ["", ".", ".."], do: {:error, :invalid_path}
  defp exact_leaf(leaf), do: {:ok, leaf}

  defp relative_child_path(path, "/") do
    case String.trim_leading(path, "/") do
      "" -> {:error, :not_regular}
      relative -> {:ok, relative}
    end
  end

  defp relative_child_path(path, root) do
    prefix = root <> "/"

    if String.starts_with?(path, prefix) do
      {:ok, String.replace_prefix(path, prefix, "")}
    else
      {:error, :path_traversal}
    end
  end

  defp read_from_pinned_root(
         resolved_root,
         {device, inode},
         relative_path,
         resolved_path,
         before_open,
         before_read
       ) do
    with {:ok, port, materialized} <-
           open_descriptor_reader(resolved_root, device, inode, relative_path) do
      await_descriptor_ready(port, materialized, resolved_path, before_open, before_read)
    end
  end

  defp open_descriptor_reader(root, device, inode, relative_path) do
    with {:ok, binary} <- native_reader_binary(),
         {:ok, materialized} <- guarded_materialize_native_reader(binary) do
      args = [
        materialized.directory,
        materialized.executable,
        root,
        Integer.to_string(device),
        Integer.to_string(inode),
        relative_path
      ]

      case open_materialized_reader(materialized.executable, args) do
        {:ok, port} ->
          # Port.open/2 can return before the child has completed exec(2).
          # The child descriptor-verifies and unlinks its own sealed image
          # before READY. Keep the parent cleanup record until READY so every
          # exec failure and timeout still gets an idempotent cleanup attempt.
          {:ok, port, materialized}

        {:error, reason} ->
          case cleanup_materialized_reader(materialized) do
            :ok -> {:error, reason}
            {:error, _cleanup_reason} -> {:error, :descriptor_materialization_failed}
          end
      end
    end
  end

  defp guarded_materialize_native_reader(binary) do
    owner = self()
    request_ref = make_ref()
    sealed_hook = current_materialization_sealed_hook()

    {guardian, guardian_monitor} =
      spawn_monitor(fn ->
        materialization_guardian(owner, request_ref, binary, sealed_hook)
      end)

    receive do
      {^request_ref, ^guardian, {:ok, materialized}} ->
        {:ok,
         Map.merge(materialized, %{
           guardian: guardian,
           guardian_monitor: guardian_monitor,
           request_ref: request_ref
         })}

      {^request_ref, ^guardian, {:error, reason}} ->
        Process.demonitor(guardian_monitor, [:flush])
        {:error, reason}

      {:DOWN, ^guardian_monitor, :process, ^guardian, _reason} ->
        {:error, :descriptor_materialization_failed}
    after
      @descriptor_ready_timeout ->
        send(guardian, {owner, request_ref, :cancel})
        Process.demonitor(guardian_monitor, [:flush])
        {:error, :descriptor_materialization_failed}
    end
  end

  defp materialization_guardian(owner, request_ref, binary, sealed_hook) do
    owner_monitor = Process.monitor(owner)

    case materialize_native_reader(
           binary,
           sealed_hook,
           owner,
           owner_monitor,
           request_ref
         ) do
      {:ok, materialized} ->
        send(owner, {request_ref, self(), {:ok, materialized}})

        receive do
          {^owner, ^request_ref, command} when command in [:cleanup, :cancel] ->
            result = remove_materialized_reader(materialized)
            send(owner, {request_ref, self(), {:cleanup, result}})

          {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
            _ = remove_materialized_reader(materialized)
        after
          @materialization_guard_timeout ->
            _ = remove_materialized_reader(materialized)
        end

      {:error, reason} ->
        send(owner, {request_ref, self(), {:error, reason}})
    end
  rescue
    _error ->
      send(owner, {request_ref, self(), {:error, :descriptor_materialization_failed}})
  catch
    _kind, _reason ->
      send(owner, {request_ref, self(), {:error, :descriptor_materialization_failed}})
  end

  defp native_reader_binary do
    module = @native_reader_artifact

    try do
      with {:module, ^module} <- Code.ensure_loaded(module),
           true <- function_exported?(module, :binary, 0),
           true <- function_exported?(module, :binary_sha256, 0),
           binary when is_binary(binary) <- apply(module, :binary, []),
           true <- byte_size(binary) > 0 and byte_size(binary) <= @native_reader_max_bytes,
           expected when is_binary(expected) <- apply(module, :binary_sha256, []),
           actual <- :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower),
           true <- byte_size(actual) == byte_size(expected),
           true <- :crypto.hash_equals(actual, expected) do
        {:ok, binary}
      else
        _other -> {:error, :descriptor_helper_unavailable}
      end
    rescue
      _error -> {:error, :descriptor_helper_unavailable}
    catch
      _kind, _reason -> {:error, :descriptor_helper_unavailable}
    end
  end

  defp materialize_native_reader(binary, sealed_hook, owner, owner_monitor, request_ref) do
    with {:ok, directory} <- create_private_reader_directory(4),
         {:ok, executable} <-
           write_private_reader_executable(
             directory,
             binary,
             sealed_hook,
             owner,
             owner_monitor,
             request_ref
           ) do
      {:ok, %{directory: directory, executable: executable}}
    else
      {:error, {:directory_created, directory}} ->
        _ = File.rm_rf(directory)
        {:error, :descriptor_materialization_failed}

      {:error, _reason} ->
        {:error, :descriptor_materialization_failed}
    end
  end

  defp create_private_reader_directory(0),
    do: {:error, :descriptor_materialization_failed}

  defp create_private_reader_directory(attempts) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    directory = Path.join(@native_reader_temp_root, @native_reader_temp_prefix <> suffix)

    case File.mkdir(directory) do
      :ok ->
        with :ok <- File.chmod(directory, 0o700),
             {:ok, %File.Stat{type: :directory, mode: mode}} <-
               File.lstat(directory, time: :posix),
             true <- Bitwise.band(mode, 0o777) == 0o700 do
          {:ok, directory}
        else
          _other -> {:error, {:directory_created, directory}}
        end

      {:error, :eexist} ->
        create_private_reader_directory(attempts - 1)

      {:error, _reason} ->
        {:error, :descriptor_materialization_failed}
    end
  end

  defp write_private_reader_executable(
         directory,
         binary,
         sealed_hook,
         owner,
         owner_monitor,
         request_ref
       ) do
    executable = Path.join(directory, "reader")

    result =
      with :ok <- write_exclusive_file(executable, binary),
           :ok <- File.chmod(executable, 0o500),
           :ok <- File.chmod(directory, 0o500),
           {:ok, %File.Stat{type: :directory, mode: directory_mode}} <-
             File.lstat(directory, time: :posix),
           true <- Bitwise.band(directory_mode, 0o777) == 0o500,
           :ok <-
             run_materialization_sealed_hook(
               directory,
               executable,
               sealed_hook,
               owner,
               owner_monitor,
               request_ref
             ),
           {:ok, %File.Stat{type: :regular, mode: mode, size: size}} <-
             File.lstat(executable, time: :posix),
           true <- Bitwise.band(mode, 0o777) == 0o500,
           true <- size == byte_size(binary),
           {:ok, written} <- File.read(executable),
           true <- byte_size(written) == byte_size(binary),
           true <-
             :crypto.hash_equals(
               :crypto.hash(:sha256, written),
               :crypto.hash(:sha256, binary)
             ) do
        {:ok, executable}
      else
        _other -> {:error, {:directory_created, directory}}
      end

    if match?({:error, _}, result) do
      _ = File.chmod(directory, 0o700)
      _ = File.rm(executable)
    end

    result
  end

  if @test_env do
    defp current_materialization_sealed_hook do
      case Process.get(@materialization_hook_key) do
        hook when is_function(hook, 2) -> hook
        _other -> nil
      end
    end

    defp run_materialization_sealed_hook(
           _directory,
           _executable,
           nil,
           _owner,
           _owner_monitor,
           _request_ref
         ),
         do: :ok

    defp run_materialization_sealed_hook(
           directory,
           executable,
           hook,
           owner,
           owner_monitor,
           request_ref
         ) do
      guardian = self()
      hook_ref = make_ref()

      {hook_process, hook_monitor} =
        spawn_monitor(fn ->
          result =
            try do
              hook.(directory, executable)
            rescue
              _error -> {:error, :sealed_hook_failed}
            catch
              _kind, _reason -> {:error, :sealed_hook_failed}
            end

          send(guardian, {hook_ref, result})
        end)

      receive do
        {^hook_ref, :ok} ->
          Process.demonitor(hook_monitor, [:flush])
          :ok

        {^hook_ref, _other} ->
          Process.demonitor(hook_monitor, [:flush])
          {:error, :sealed_hook_failed}

        {:DOWN, ^hook_monitor, :process, ^hook_process, _reason} ->
          {:error, :sealed_hook_failed}

        {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
          Process.exit(hook_process, :kill)
          {:error, :owner_down}

        {^owner, ^request_ref, :cancel} ->
          Process.exit(hook_process, :kill)
          {:error, :owner_down}
      end
    end
  else
    defp current_materialization_sealed_hook, do: nil

    defp run_materialization_sealed_hook(
           _directory,
           _executable,
           _hook,
           _owner,
           _owner_monitor,
           _request_ref
         ),
         do: :ok
  end

  defp write_exclusive_file(path, binary) do
    case File.open(path, [:write, :binary, :raw, :exclusive]) do
      {:ok, io_device} ->
        write_result =
          with :ok <- :file.write(io_device, binary),
               :ok <- :file.sync(io_device) do
            :ok
          end

        close_result = File.close(io_device)

        case {write_result, close_result} do
          {:ok, :ok} -> :ok
          _other -> {:error, :write_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_materialized_reader(executable, args) do
    try do
      {:ok,
       Port.open({:spawn_executable, to_charlist(executable)}, [
         :binary,
         :exit_status,
         :use_stdio,
         args: Enum.map(args, &to_charlist/1)
       ])}
    catch
      :error, _reason -> {:error, :descriptor_helper_unavailable}
    end
  end

  defp cleanup_materialized_reader(%{
         guardian: guardian,
         guardian_monitor: guardian_monitor,
         request_ref: request_ref
       }) do
    send(guardian, {self(), request_ref, :cleanup})

    receive do
      {^request_ref, ^guardian, {:cleanup, result}} ->
        Process.demonitor(guardian_monitor, [:flush])
        result

      {:DOWN, ^guardian_monitor, :process, ^guardian, _reason} ->
        {:error, :cleanup_failed}
    after
      @descriptor_ready_timeout ->
        {:error, :cleanup_failed}
    end
  end

  defp remove_materialized_reader(%{directory: directory, executable: executable}) do
    case File.chmod(directory, 0o700) do
      :ok ->
        file_result = File.rm(executable)
        directory_result = File.rmdir(directory)

        case {file_result, directory_result} do
          {file_result, directory_result}
          when file_result in [:ok, {:error, :enoent}] and
                 directory_result in [:ok, {:error, :enoent}] ->
            :ok

          _other ->
            _ = File.rm_rf(directory)
            {:error, :cleanup_failed}
        end

      {:error, :enoent} ->
        :ok

      {:error, _reason} ->
        _ = File.rm_rf(directory)
        {:error, :cleanup_failed}
    end
  end

  defp await_descriptor_ready(port, materialized, resolved_path, before_open, before_read) do
    deadline = System.monotonic_time(:millisecond) + @descriptor_ready_timeout

    receive_descriptor_ready(
      port,
      materialized,
      <<>>,
      deadline,
      resolved_path,
      before_open,
      before_read
    )
  end

  defp receive_descriptor_ready(
         port,
         materialized,
         buffered,
         deadline,
         resolved_path,
         before_open,
         before_read
       ) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      close_reader_before_ready(port, materialized, :descriptor_timeout)
    else
      receive do
        {^port, {:data, data}} when is_binary(data) ->
          ready = buffered <> data

          cond do
            ready == "READY\n" ->
              case cleanup_materialized_reader(materialized) do
                :ok ->
                  continue_descriptor_open(port, resolved_path, before_open, before_read)

                {:error, _reason} ->
                  close_descriptor_reader(port)
                  {:error, :descriptor_materialization_failed}
              end

            byte_size(ready) < 6 and String.starts_with?("READY\n", ready) ->
              receive_descriptor_ready(
                port,
                materialized,
                ready,
                deadline,
                resolved_path,
                before_open,
                before_read
              )

            true ->
              close_reader_before_ready(port, materialized, :descriptor_protocol_error)
          end

        {^port, {:exit_status, status}} ->
          close_reader_before_ready(port, materialized, reader_error(status))

        {:EXIT, ^port, _reason} ->
          close_reader_before_ready(port, materialized, :descriptor_helper_unavailable)
      after
        remaining ->
          close_reader_before_ready(port, materialized, :descriptor_timeout)
      end
    end
  end

  defp close_reader_before_ready(port, materialized, reason) do
    close_descriptor_reader(port)

    case cleanup_materialized_reader(materialized) do
      :ok -> {:error, reason}
      {:error, _cleanup_reason} -> {:error, :descriptor_materialization_failed}
    end
  end

  defp continue_descriptor_open(port, resolved_path, before_open, before_read) do
    case invoke_before_open(before_open) do
      :ok ->
        if command_descriptor_reader(port, "O") do
          deadline = System.monotonic_time(:millisecond) + @descriptor_ready_timeout
          receive_descriptor_opened(port, <<>>, deadline, resolved_path, before_read)
        else
          close_descriptor_reader(port)
          {:error, :descriptor_helper_unavailable}
        end

      {:error, reason} ->
        _sent? = command_descriptor_reader(port, "X")
        close_descriptor_reader(port)
        {:error, reason}
    end
  end

  defp receive_descriptor_opened(port, buffered, deadline, resolved_path, before_read) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      close_descriptor_reader(port)
      {:error, :descriptor_timeout}
    else
      receive do
        {^port, {:data, data}} when is_binary(data) ->
          opened = buffered <> data

          cond do
            opened == "FILE\n" ->
              continue_descriptor_read(port, resolved_path, before_read)

            byte_size(opened) < 5 and String.starts_with?("FILE\n", opened) ->
              receive_descriptor_opened(port, opened, deadline, resolved_path, before_read)

            true ->
              close_descriptor_reader(port)
              {:error, :descriptor_protocol_error}
          end

        {^port, {:exit_status, status}} ->
          {:error, reader_error(status)}

        {:EXIT, ^port, _reason} ->
          {:error, :descriptor_helper_unavailable}
      after
        remaining ->
          close_descriptor_reader(port)
          {:error, :descriptor_timeout}
      end
    end
  end

  defp continue_descriptor_read(port, resolved_path, before_read) do
    case invoke_before_read(before_read, resolved_path) do
      :ok ->
        if command_descriptor_reader(port, "R") do
          deadline = System.monotonic_time(:millisecond) + @descriptor_read_timeout
          collect_descriptor_read(port, [], deadline, resolved_path)
        else
          close_descriptor_reader(port)
          {:error, :descriptor_helper_unavailable}
        end

      {:error, reason} ->
        _sent? = command_descriptor_reader(port, "X")
        close_descriptor_reader(port)
        {:error, reason}
    end
  end

  defp invoke_before_open(before_open) do
    try do
      case before_open.() do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        _other -> {:error, :path_changed}
      end
    rescue
      _error -> {:error, :path_changed}
    catch
      _kind, _reason -> {:error, :path_changed}
    end
  end

  defp invoke_before_read(before_read, resolved_path) do
    try do
      case before_read.(resolved_path) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        _other -> {:error, :path_changed}
      end
    rescue
      _error -> {:error, :path_changed}
    catch
      _kind, _reason -> {:error, :path_changed}
    end
  end

  defp command_descriptor_reader(port, command) do
    try do
      Port.command(port, command)
    catch
      :error, _reason -> false
    end
  end

  defp collect_descriptor_read(port, chunks, deadline, resolved_path) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      close_descriptor_reader(port)
      {:error, :descriptor_timeout}
    else
      receive do
        {^port, {:data, data}} when is_binary(data) ->
          collect_descriptor_read(port, [data | chunks], deadline, resolved_path)

        {^port, {:exit_status, 0}} ->
          chunks
          |> Enum.reverse()
          |> IO.iodata_to_binary()
          |> decode_descriptor_content(resolved_path)

        {^port, {:exit_status, status}} ->
          {:error, reader_error(status)}

        {:EXIT, ^port, _reason} ->
          {:error, :descriptor_helper_unavailable}
      after
        remaining ->
          close_descriptor_reader(port)
          {:error, :descriptor_timeout}
      end
    end
  end

  defp decode_descriptor_content("DATA\n" <> content, resolved_path),
    do: {:ok, content, resolved_path}

  defp decode_descriptor_content(_other, _resolved_path),
    do: {:error, :descriptor_protocol_error}

  defp close_descriptor_reader(port) do
    try do
      Port.close(port)
    catch
      :error, _reason -> :ok
    end

    :ok
  end

  defp reader_error(@reader_invalid), do: :descriptor_protocol_error
  defp reader_error(@reader_root_identity), do: :path_changed
  defp reader_error(@reader_symlink), do: :path_changed
  defp reader_error(@reader_not_found), do: :enoent
  defp reader_error(@reader_not_regular), do: :not_regular
  defp reader_error(@reader_io), do: :eio
  defp reader_error(@reader_protocol), do: :descriptor_protocol_error
  defp reader_error(_status), do: :descriptor_helper_unavailable

  defp contained_path?(_path, "/"), do: true

  defp contained_path?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  # Maximum number of symlinks to follow before declaring a loop (mirrors the
  # POSIX MAXSYMLINKS / ELOOP guard). Counts only symlink hops, not path depth.
  @max_symlink_hops 40

  # True realpath: walk the path component-by-component from filesystem root,
  # resolving a symlink whenever one is encountered (ancestor OR leaf). A
  # relative link target resolves against the directory containing the link; an
  # absolute target restarts from "/". `resolved` is always the already-
  # canonicalized prefix, so `..` simply pops it.
  defp resolve_real_manual(path) do
    path
    |> absolute_without_normalizing()
    |> path_components()
    |> then(&walk_symlinks("/", &1, 0, false))
  end

  # Containment checks also need to support a not-yet-created leaf. Existing
  # components are resolved exactly as `resolve_real/1`; after the first
  # missing component, the remaining lexical components are still processed
  # in order so `..` cannot escape the resolved prefix.
  defp resolve_real_allow_missing(path) do
    path
    |> absolute_without_normalizing()
    |> path_components()
    |> then(&walk_symlinks("/", &1, 0, true))
  end

  defp absolute_without_normalizing(path) do
    if absolute?(path) do
      path
    else
      String.trim_trailing(File.cwd!(), "/") <> "/" <> path
    end
  end

  defp path_components(path) do
    case Path.split(path) do
      ["/" | rest] -> rest
      rest -> rest
    end
  end

  # Loop guard: too many symlink hops → treat as unresolvable.
  defp walk_symlinks(_resolved, _rest, hops, _allow_missing?)
       when hops > @max_symlink_hops do
    {:error, :not_found}
  end

  defp walk_symlinks(resolved, [], _hops, _allow_missing?),
    do: {:ok, ensure_root(resolved)}

  defp walk_symlinks(resolved, ["." | rest], hops, allow_missing?),
    do: walk_symlinks(resolved, rest, hops, allow_missing?)

  defp walk_symlinks(resolved, [".." | rest], hops, allow_missing?),
    do: walk_symlinks(Path.dirname(resolved), rest, hops, allow_missing?)

  defp walk_symlinks(resolved, [comp | rest], hops, allow_missing?) do
    candidate = Path.join(resolved, comp)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        # `comp` is a symlink. Re-inject the link target ahead of the remaining
        # components and count the hop. Absolute targets restart from root;
        # relative targets resolve against `resolved` (the link's directory).
        case File.read_link(candidate) do
          {:ok, target} ->
            if absolute?(target) do
              walk_symlinks("/", path_components(target) ++ rest, hops + 1, allow_missing?)
            else
              walk_symlinks(
                resolved,
                path_components(target) ++ rest,
                hops + 1,
                allow_missing?
              )
            end

          {:error, _reason} ->
            {:error, :not_found}
        end

      {:ok, _stat} ->
        walk_symlinks(candidate, rest, hops, allow_missing?)

      {:error, :enoent} when allow_missing? ->
        walk_symlinks(candidate, rest, hops, allow_missing?)

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  defp ensure_root(""), do: "/"
  defp ensure_root(resolved), do: resolved

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

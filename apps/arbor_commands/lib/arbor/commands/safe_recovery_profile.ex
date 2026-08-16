defmodule Arbor.Commands.SafeRecoveryProfile do
  @moduledoc """
  Imperative shell for the E0B1 safe-recovery profile evidence.

  Production reads only the fixed reviewed candidate at
  `apps/arbor_commands/priv/packaging/safe_recovery_profile.v1.json`.
  `run/1` admits only CLI-facing options; a synthetic profile is confined
  to `run_for_test/1`.

  The 256 KiB ceiling is a protective outer bound over the frozen 40-entry
  v1 shape: 40 entries times Encode's 4,000-byte rationale limit, rounded
  to 4,096 bytes, plus keys, structure, and headroom. The reader always
  reads at most ceiling+1 bytes so a lying or racing stat cannot force an
  unbounded read.
  """

  alias Arbor.Commands.PackagingRoot
  alias Arbor.Commands.SafeRecoveryProfile.{Core, Encode}
  alias Arbor.Common.SafePath

  @default_profile_rel "apps/arbor_commands/priv/packaging/safe_recovery_profile.v1.json"
  @max_profile_bytes 256 * 1024
  @expected_profile_digest "55fda49eb5389dcb7acd8d90ccd3e20961cf5176a563eb75c32f6848e227d2d5"
  @profile_io_timeout_ms 1_000
  @profile_opened_event [:arbor, :commands, :safe_recovery_profile, :opened]

  @production_opt_keys MapSet.new([:mode, :json, :root])
  @test_opt_keys MapSet.union(@production_opt_keys, MapSet.new([:profile]))

  @default_opts %{mode: "report", json: false, root: nil, profile: nil}

  @doc """
  Admit the fixed reviewed safe-recovery candidate from a trusted root.

  Accepted options are `:mode`, `:json`, and `:root` only.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) do
    with {:ok, admitted, seen} <- admit_options(opts, :production) do
      do_run(admitted, seen, allow_synthetic: false)
    end
  end

  @doc false
  @spec run_for_test(keyword()) :: {:ok, map()} | {:error, term()}
  def run_for_test(opts) do
    with {:ok, admitted, seen} <- admit_options(opts, :test) do
      do_run(admitted, seen, allow_synthetic: true)
    end
  end

  @doc false
  @spec default_profile_path() :: String.t()
  def default_profile_path, do: @default_profile_rel

  @doc false
  @spec max_profile_bytes() :: pos_integer()
  def max_profile_bytes, do: @max_profile_bytes

  defp do_run(opts, seen, allow_synthetic: allow_synthetic) do
    with {:ok, root} <- resolve_root(opts.root),
         {:ok, profile, digest} <- load_profile(root, opts, seen, allow_synthetic) do
      build_result(opts, profile, digest)
    end
  end

  defp resolve_root(path) do
    with {:ok, root} <- PackagingRoot.resolve(path),
         :ok <- reject_root_symlink(root),
         {:ok, real_root} <- SafePath.resolve_real(root) do
      {:ok, real_root}
    else
      {:error, :not_found} -> {:error, :invalid_root_marker}
      {:error, _} = error -> error
    end
  end

  defp reject_root_symlink(root) do
    case File.read_link(root) do
      {:ok, _} -> {:error, :root_symlink_redirection}
      {:error, :einval} -> :ok
      {:error, :enoent} -> {:error, :invalid_root_marker}
      {:error, reason} -> {:error, {:root_read_link, reason}}
    end
  end

  defp load_profile(root, opts, seen, true) do
    if MapSet.member?(seen, :profile) do
      admit_profile(opts.profile, :synthetic)
    else
      load_fixed_profile(root)
    end
  end

  defp load_profile(root, _opts, _seen, false), do: load_fixed_profile(root)

  defp load_fixed_profile(root) do
    with {:ok, path} <- resolve_profile_path(root),
         {:ok, bytes} <- read_profile_bytes(path, root),
         {:ok, decoded} <- decode_profile(bytes) do
      admit_profile(decoded, :production)
    end
  end

  defp resolve_profile_path(root) do
    with {:ok, lexical} <- SafePath.safe_join(root, @default_profile_rel),
         :ok <- require_within(lexical, root),
         {:ok, real} <- resolve_profile_real(lexical),
         :ok <- require_within(real, root),
         :ok <- require_unredirected(lexical, real) do
      {:ok, lexical}
    else
      {:error, :path_traversal} -> {:error, :profile_path_escape}
      {:error, _} = error -> error
    end
  end

  defp require_within(path, root) do
    if SafePath.within?(path, root), do: :ok, else: {:error, :profile_path_escape}
  end

  defp resolve_profile_real(path) do
    case SafePath.resolve_real(path) do
      {:ok, real} -> {:ok, real}
      {:error, :not_found} -> {:error, :profile_missing}
    end
  end

  defp require_unredirected(path, path), do: :ok
  defp require_unredirected(_lexical, _real), do: {:error, :profile_symlink_redirection}

  defp read_profile_bytes(path, root) do
    caller = self()
    request_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(caller, {request_ref, read_open_profile(path, root)})
      end)

    await_profile_reader(pid, monitor_ref, request_ref)
  end

  defp await_profile_reader(pid, monitor_ref, request_ref) do
    receive do
      {^request_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        {:error, :profile_read_failed}
    after
      @profile_io_timeout_ms ->
        Process.exit(pid, :kill)
        await_reader_shutdown(pid, monitor_ref, request_ref)
        {:error, :profile_read_timeout}
    end
  end

  defp await_reader_shutdown(pid, monitor_ref, request_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      @profile_io_timeout_ms -> Process.demonitor(monitor_ref, [:flush])
    end

    receive do
      {^request_ref, _late_result} -> :ok
    after
      0 -> :ok
    end
  end

  defp read_open_profile(path, root) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          with {:ok, opened_identity} <- descriptor_regular_identity(io),
               :ok <- emit_profile_opened(path),
               :ok <- verify_open_profile(path, root, opened_identity),
               {:ok, bytes} <- read_descriptor(io),
               {:ok, final_identity} <- descriptor_regular_identity(io),
               true <- final_identity == opened_identity,
               :ok <- verify_open_profile(path, root, final_identity) do
            {:ok, bytes}
          else
            false -> {:error, :profile_changed_during_read}
            {:error, _} = error -> error
          end
        after
          :file.close(io)
        end

      {:error, :enoent} ->
        {:error, :profile_missing}

      {:error, :eisdir} ->
        {:error, :profile_not_regular}

      {:error, reason} ->
        {:error, {:profile_read, reason}}
    end
  end

  defp descriptor_regular_identity(io) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, info} -> info |> File.Stat.from_record() |> regular_identity()
      {:error, reason} -> {:error, {:profile_read, reason}}
    end
  end

  defp path_regular_identity(path) do
    case File.lstat(path, time: :posix) do
      {:ok, stat} -> regular_identity(stat)
      {:error, :enoent} -> {:error, :profile_missing}
      {:error, reason} -> {:error, {:profile_stat, reason}}
    end
  end

  defp regular_identity(%File.Stat{type: :regular} = stat) do
    {:ok,
     %{
       type: stat.type,
       inode: stat.inode,
       major_device: stat.major_device,
       minor_device: stat.minor_device,
       size: stat.size,
       mtime: stat.mtime,
       ctime: stat.ctime
     }}
  end

  defp regular_identity(%File.Stat{}), do: {:error, :profile_not_regular}

  defp verify_open_profile(path, root, expected_identity) do
    with {:ok, real} <- resolve_profile_real(path),
         :ok <- require_within(real, root),
         :ok <- require_unredirected(path, real),
         {:ok, current_identity} <- path_regular_identity(path),
         true <- current_identity == expected_identity do
      :ok
    else
      _other -> {:error, :profile_changed_during_read}
    end
  end

  defp emit_profile_opened(path) do
    # Post-open, pre-verify TOCTOU seam used by the security-regression tests.
    :telemetry.execute(@profile_opened_event, %{count: 1}, %{path: path})
    :ok
  end

  defp read_descriptor(io) do
    case :file.read(io, @max_profile_bytes + 1) do
      {:ok, bytes} -> admit_read_bytes(bytes)
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, {:profile_read, reason}}
    end
  end

  defp admit_read_bytes(bytes) when byte_size(bytes) > @max_profile_bytes,
    do: {:error, :profile_too_large}

  defp admit_read_bytes(bytes), do: {:ok, bytes}

  defp decode_profile(bytes) do
    case Jason.decode(bytes) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :profile_invalid_json}
    end
  end

  defp admit_profile(decoded, kind) do
    with {:ok, projected} <- Core.project(decoded),
         :ok <- require_canonical_order(decoded, projected),
         :ok <- Encode.validate_profile(projected),
         {:ok, digest} <- Encode.profile_digest(projected),
         :ok <- require_reviewed_identity(kind, digest) do
      {:ok, projected, digest}
    end
  end

  defp require_reviewed_identity(:synthetic, _digest), do: :ok
  defp require_reviewed_identity(:production, @expected_profile_digest), do: :ok
  defp require_reviewed_identity(:production, _digest), do: {:error, :profile_identity_mismatch}

  defp require_canonical_order(decoded, projected) do
    normalized = stringify_map_keys(decoded)

    projected
    |> Enum.filter(fn {_field, value} -> is_list(value) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.find(fn {field, canonical} -> Map.get(normalized, field) != canonical end)
    |> case do
      nil -> :ok
      {field, _canonical} -> {:error, {:candidate_not_canonical, field}}
    end
  end

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {stringify_key(key), stringify_map_keys(value)} end)
  end

  defp stringify_map_keys(list) when is_list(list), do: Enum.map(list, &stringify_map_keys/1)
  defp stringify_map_keys(value), do: value

  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: key

  defp build_result(opts, profile, digest) do
    output = if opts.json, do: "json", else: "human"

    {:ok,
     %{
       "mode" => opts.mode,
       "output" => output,
       "profile" => profile,
       "profile_digest" => digest
     }}
  end

  defp admit_options(opts, kind) when is_list(opts) do
    allowed = if kind == :production, do: @production_opt_keys, else: @test_opt_keys

    Enum.reduce_while(opts, {:ok, @default_opts, MapSet.new()}, fn option,
                                                                   {:ok, admitted, seen} ->
      admit_option(option, admitted, seen, allowed, kind)
    end)
  end

  defp admit_options(_opts, _kind), do: {:error, :invalid_opts}

  defp admit_option({key, value}, admitted, seen, allowed, kind) when is_atom(key) do
    cond do
      MapSet.member?(seen, key) ->
        {:halt, {:error, {:duplicate_option, key}}}

      not MapSet.member?(allowed, key) ->
        {:halt, unknown_option(kind, key)}

      true ->
        case validate_option(key, value) do
          :ok ->
            {:cont, {:ok, Map.put(admitted, key, value), MapSet.put(seen, key)}}

          {:error, _} = error ->
            {:halt, error}
        end
    end
  end

  defp admit_option(_option, _admitted, _seen, _allowed, _kind),
    do: {:halt, {:error, :invalid_opts}}

  defp unknown_option(:production, key),
    do: {:error, {:production_opts_forbid_synthetic, [key]}}

  defp unknown_option(:test, key), do: {:error, {:unknown_option, key}}

  defp validate_option(:mode, mode) when mode in ["report", "check"], do: :ok
  defp validate_option(:json, json) when is_boolean(json), do: :ok
  defp validate_option(:root, nil), do: :ok
  defp validate_option(:root, value) when is_binary(value), do: :ok

  defp validate_option(:profile, profile) when is_map(profile) and not is_struct(profile),
    do: :ok

  defp validate_option(key, _value), do: {:error, {:invalid_option, key}}
end

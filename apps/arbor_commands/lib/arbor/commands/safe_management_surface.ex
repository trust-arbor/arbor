defmodule Arbor.Commands.SafeManagementSurface do
  @moduledoc """
  Imperative shell for the P1A safe-management surface.

  Production gathers a closed operation and a size-bounded SafePath receipt
  JSON, injects `authorization_status` independently as `"absent"`, calls
  `Arbor.KernelRuntime.SafeManagementSurface.project/1` once, and returns
  that decision document. It never applies mutation effects.

  A receipt is never bearer authority. `run/1` cannot set authorization to
  verified. `run_for_test/1` is the only seam that may inject a closed
  authorization status to prove CRC wiring.
  """

  alias Arbor.Commands.PackagingRoot
  alias Arbor.Common.SafePath
  alias Arbor.KernelRuntime.SafeManagementSurface, as: KernelSurface

  @max_receipt_bytes 64 * 1024
  @operations MapSet.new(["clean", "disable", "list", "revoke", "rollback"])
  @authorization_statuses MapSet.new(["absent", "invalid", "revoked", "verified"])

  @production_opt_keys MapSet.new([:operation, :receipt, :root])
  @test_opt_keys MapSet.union(@production_opt_keys, MapSet.new([:authorization_status]))

  @default_opts %{
    operation: nil,
    receipt: nil,
    root: nil,
    authorization_status: "absent"
  }

  @doc """
  Project one safe-management decision from a receipt path.

  Accepted options are `:operation`, `:receipt`, and `:root` only.
  Authorization is always injected as `"absent"`.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) do
    with {:ok, admitted} <- admit_options(opts, :production) do
      do_run(admitted)
    end
  end

  @doc false
  @spec run_for_test(keyword()) :: {:ok, map()} | {:error, term()}
  def run_for_test(opts) do
    with {:ok, admitted} <- admit_options(opts, :test) do
      do_run(admitted)
    end
  end

  @doc false
  @spec max_receipt_bytes() :: pos_integer()
  def max_receipt_bytes, do: @max_receipt_bytes

  defp do_run(opts) do
    with {:ok, root} <- resolve_root(opts.root),
         {:ok, receipt} <- load_receipt(root, opts.receipt) do
      KernelSurface.project(%{
        "schema" => KernelSurface.schema(),
        "version" => 1,
        "operation" => opts.operation,
        "authorization_status" => opts.authorization_status,
        "receipt" => receipt
      })
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

  defp load_receipt(root, receipt_path) do
    with {:ok, path} <- resolve_receipt_path(root, receipt_path),
         {:ok, bytes} <- read_receipt_bytes(path, root),
         {:ok, decoded} <- decode_receipt(bytes) do
      {:ok, decoded}
    end
  end

  defp resolve_receipt_path(root, receipt_path) do
    with :ok <- validate_receipt_path(receipt_path),
         {:ok, lexical} <- receipt_lexical(root, receipt_path),
         :ok <- require_within(lexical, root),
         {:ok, real} <- resolve_receipt_real(lexical),
         :ok <- require_within(real, root),
         :ok <- require_unredirected(lexical, real) do
      {:ok, lexical}
    else
      {:error, :path_traversal} -> {:error, :receipt_path_escape}
      {:error, :not_found} -> {:error, :receipt_missing}
      {:error, _} = error -> error
    end
  end

  defp validate_receipt_path(path) do
    case SafePath.validate(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:receipt_path, reason}}
    end
  end

  defp receipt_lexical(root, receipt_path) do
    if SafePath.absolute?(receipt_path) do
      {:ok, Path.expand(receipt_path)}
    else
      SafePath.safe_join(root, receipt_path)
    end
  end

  defp require_within(path, root) do
    if SafePath.within?(path, root), do: :ok, else: {:error, :receipt_path_escape}
  end

  defp resolve_receipt_real(path) do
    case SafePath.resolve_real(path) do
      {:ok, real} -> {:ok, real}
      {:error, :not_found} -> {:error, :receipt_missing}
    end
  end

  defp require_unredirected(path, path), do: :ok
  defp require_unredirected(_lexical, _real), do: {:error, :receipt_symlink_redirection}

  defp read_receipt_bytes(path, root) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          with {:ok, opened_identity} <- descriptor_regular_identity(io),
               :ok <- verify_open_receipt(path, root, opened_identity),
               {:ok, bytes} <- read_descriptor(io),
               {:ok, final_identity} <- descriptor_regular_identity(io),
               true <- final_identity == opened_identity,
               :ok <- verify_open_receipt(path, root, final_identity) do
            {:ok, bytes}
          else
            false -> {:error, :receipt_changed_during_read}
            {:error, _} = error -> error
          end
        after
          :file.close(io)
        end

      {:error, :enoent} ->
        {:error, :receipt_missing}

      {:error, :eisdir} ->
        {:error, :receipt_not_regular}

      {:error, reason} ->
        {:error, {:receipt_read, reason}}
    end
  end

  defp descriptor_regular_identity(io) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, info} -> info |> File.Stat.from_record() |> regular_identity()
      {:error, reason} -> {:error, {:receipt_read, reason}}
    end
  end

  defp path_regular_identity(path) do
    case File.lstat(path, time: :posix) do
      {:ok, stat} -> regular_identity(stat)
      {:error, :enoent} -> {:error, :receipt_missing}
      {:error, reason} -> {:error, {:receipt_stat, reason}}
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

  defp regular_identity(%File.Stat{}), do: {:error, :receipt_not_regular}

  defp verify_open_receipt(path, root, expected_identity) do
    with {:ok, real} <- resolve_receipt_real(path),
         :ok <- require_within(real, root),
         :ok <- require_unredirected(path, real),
         {:ok, current_identity} <- path_regular_identity(path) do
      if current_identity == expected_identity do
        :ok
      else
        {:error, :receipt_changed_during_read}
      end
    end
  end

  defp read_descriptor(io) do
    case :file.read(io, @max_receipt_bytes + 1) do
      {:ok, bytes} -> admit_read_bytes(bytes)
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, {:receipt_read, reason}}
    end
  end

  defp admit_read_bytes(bytes) when byte_size(bytes) > @max_receipt_bytes,
    do: {:error, :receipt_too_large}

  defp admit_read_bytes(bytes), do: {:ok, bytes}

  defp decode_receipt(bytes) do
    case Jason.decode(bytes) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :receipt_invalid_json}
    end
  end

  defp admit_options(opts, kind) when is_list(opts) do
    allowed = if kind == :production, do: @production_opt_keys, else: @test_opt_keys

    result =
      Enum.reduce_while(opts, {:ok, @default_opts, MapSet.new()}, fn option,
                                                                    {:ok, admitted, seen} ->
        admit_option(option, admitted, seen, allowed, kind)
      end)

    case result do
      {:ok, admitted, seen} ->
        with :ok <- require_seen(seen, :operation),
             :ok <- require_seen(seen, :receipt) do
          {:ok, admitted}
        end

      {:error, _} = error ->
        error
    end
  end

  defp admit_options(_opts, _kind), do: {:error, :invalid_opts}

  defp require_seen(seen, key) do
    if MapSet.member?(seen, key), do: :ok, else: {:error, {:missing_option, key}}
  end

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

  defp validate_option(:operation, operation) do
    if MapSet.member?(@operations, operation) do
      :ok
    else
      {:error, {:invalid_option, :operation}}
    end
  end

  defp validate_option(:receipt, receipt) when is_binary(receipt) and receipt != "", do: :ok
  defp validate_option(:root, nil), do: :ok
  defp validate_option(:root, value) when is_binary(value), do: :ok

  defp validate_option(:authorization_status, status) do
    if MapSet.member?(@authorization_statuses, status) do
      :ok
    else
      {:error, {:invalid_option, :authorization_status}}
    end
  end

  defp validate_option(key, _value), do: {:error, {:invalid_option, key}}
end

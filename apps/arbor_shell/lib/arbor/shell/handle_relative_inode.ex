defmodule Arbor.Shell.HandleRelativeInode do
  @moduledoc false

  alias Arbor.Shell.HandleRelativeInodeCore

  @chunk 8_192
  @native_retained %{
    "source_race" => :source_race,
    "destination_race" => :destination_race,
    "stage_name_race" => :stage_name_race,
    "fsync_failed" => :fsync_failed,
    "post_state_unproved" => :post_state_unproved
  }
  @identity_keys [:path, :type, :device, :minor_device, :inode, :mode, :uid, :gid, :size, :nlink]

  @spec apply(term()) ::
          {:ok, map()} | {:error, atom()} | {:error, {:retained_ambiguity, atom(), map()}}
  def apply(request) do
    with {:ok, plan} <- HandleRelativeInodeCore.admit(request),
         :ok <- platform() do
      launch(plan)
    end
  end

  @doc false
  @spec decode_port_result(map(), integer(), binary()) ::
          {:ok, map()} | {:error, atom()} | {:error, {:retained_ambiguity, atom(), map()}}
  def decode_port_result(plan, status, output)
      when is_map(plan) and is_integer(status) and is_binary(output) do
    decode(plan, status, output)
  end

  @doc false
  @spec map_collect_failure(map(), :timeout | :port_death | :output_unbounded) ::
          {:error, atom()} | {:error, {:retained_ambiguity, atom(), map()}}
  def map_collect_failure(plan, :timeout), do: finish_timeout(plan)
  def map_collect_failure(plan, :port_death), do: finish_port_death(plan)
  def map_collect_failure(plan, :output_unbounded), do: finish_unbounded(plan)

  defp platform do
    case :os.type() do
      {:unix, :darwin} -> :ok
      {:unix, :linux} -> :ok
      _other -> {:error, :unsupported_platform}
    end
  end

  defp launch(plan) do
    case launcher_path() do
      {:error, :launcher_unavailable} ->
        {:error, :launcher_unavailable}

      {:ok, launcher} ->
        case open_port(launcher, plan) do
          {:error, :launcher_unavailable} ->
            {:error, :launcher_unavailable}

          {:ok, port} ->
            try do
              deadline = System.monotonic_time(:millisecond) + plan.timeout_ms
              collect(port, plan, plan.payload, [], 0, deadline)
            catch
              :error, _reason ->
                close_port(port)
                finish_port_death(plan)
            end
        end
    end
  end

  defp open_port(launcher, plan) do
    try do
      {:ok,
       Port.open({:spawn_executable, to_charlist(launcher)}, [
         :binary,
         :exit_status,
         :use_stdio,
         :stderr_to_stdout,
         args: Enum.map(plan.argv, &to_charlist/1)
       ])}
    catch
      :error, _reason -> {:error, :launcher_unavailable}
    end
  end

  defp launcher_path do
    case :code.priv_dir(:arbor_shell) do
      path when is_list(path) ->
        launcher = Path.join(List.to_string(path), "arbor_shell_launcher")

        case File.lstat(launcher, time: :posix) do
          {:ok, %File.Stat{type: :regular}} -> {:ok, launcher}
          _other -> {:error, :launcher_unavailable}
        end

      _other ->
        {:error, :launcher_unavailable}
    end
  end

  defp collect(port, plan, payload, chunks, size, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    cond do
      remaining <= 0 ->
        close_port(port)
        finish_timeout(plan)

      byte_size(payload) > 0 ->
        {chunk, rest} = next_chunk(payload)

        try do
          true = Port.command(port, chunk)
          collect(port, plan, rest, chunks, size, deadline)
        catch
          :error, _reason ->
            close_port(port)
            finish_port_death(plan)
        end

      true ->
        receive_output(port, plan, chunks, size, deadline, remaining)
    end
  end

  defp next_chunk(payload) do
    if byte_size(payload) <= @chunk do
      {payload, <<>>}
    else
      <<chunk::binary-size(@chunk), rest::binary>> = payload
      {chunk, rest}
    end
  end

  defp receive_output(port, plan, chunks, size, deadline, remaining) do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        next_size = size + byte_size(data)

        if next_size <= plan.max_output do
          collect(port, plan, <<>>, [data | chunks], next_size, deadline)
        else
          close_port(port)
          finish_unbounded(plan)
        end

      {^port, {:exit_status, status}} ->
        output = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        decode(plan, status, output)

      {:EXIT, ^port, _reason} ->
        finish_port_death(plan)
    after
      remaining ->
        close_port(port)
        finish_timeout(plan)
    end
  end

  defp finish_timeout(%{mutating?: true, names: names}), do: retained(:timeout, names)
  defp finish_timeout(_plan), do: {:error, :timeout}

  defp finish_port_death(%{mutating?: true, names: names}), do: retained(:port_death, names)
  defp finish_port_death(_plan), do: {:error, :port_death}

  defp finish_unbounded(%{mutating?: true, names: names}), do: retained(:output_unbounded, names)
  defp finish_unbounded(_plan), do: {:error, :output_unbounded}

  defp retained(reason, names), do: {:error, {:retained_ambiguity, reason, names}}

  defp decode(plan, 0, output) do
    case parse_success(output, plan.operation) do
      {:ok, result} -> {:ok, result}
      {:error, :output_empty} -> finish_decode(plan, :output_empty)
      {:error, :output_incomplete} -> finish_decode(plan, :output_incomplete)
      {:error, :output_unparseable} -> finish_decode(plan, :output_unparseable)
    end
  end

  defp decode(%{mutating?: false}, status, _output), do: {:error, observe_exit(status)}

  defp decode(%{mutating?: true}, 64, _output), do: {:error, :invalid_request}
  defp decode(%{mutating?: true}, 65, _output), do: {:error, :not_found}
  defp decode(%{mutating?: true}, 66, _output), do: {:error, :symlink_rejected}
  defp decode(%{mutating?: true}, 67, _output), do: {:error, :hardlink_rejected}
  defp decode(%{mutating?: true}, 68, _output), do: {:error, :invalid_type}
  defp decode(%{mutating?: true}, 69, _output), do: {:error, :identity_mismatch}
  defp decode(%{mutating?: true}, 72, _output), do: {:error, :destination_exists}
  defp decode(%{mutating?: true}, 73, _output), do: {:error, :cross_device}
  defp decode(%{mutating?: true}, 74, _output), do: {:error, :directory_not_exclusive}
  defp decode(%{mutating?: true}, 76, _output), do: {:error, :unsupported_platform}

  defp decode(%{mutating?: true, names: names}, 75, output) do
    case parse_retained(output) do
      {:ok, reason} -> retained(reason, names)
      :error -> retained(:output_unparseable, names)
    end
  end

  defp decode(%{mutating?: true, names: names}, 70, _output), do: retained(:io_failed, names)

  defp decode(%{mutating?: true, names: names}, 71, _output),
    do: retained(:output_unparseable, names)

  defp decode(%{mutating?: true, names: names}, 126, _output), do: retained(:port_death, names)

  defp decode(%{mutating?: true, names: names}, _status, _output),
    do: retained(:post_state_unproved, names)

  defp finish_decode(%{mutating?: true, names: names}, reason), do: retained(reason, names)
  defp finish_decode(_plan, reason), do: {:error, reason}

  defp observe_exit(64), do: :invalid_request
  defp observe_exit(65), do: :not_found
  defp observe_exit(66), do: :symlink_rejected
  defp observe_exit(67), do: :hardlink_rejected
  defp observe_exit(68), do: :invalid_type
  defp observe_exit(69), do: :identity_mismatch
  defp observe_exit(70), do: :io_failed
  defp observe_exit(71), do: :output_unparseable
  defp observe_exit(74), do: :directory_not_exclusive
  defp observe_exit(72), do: :io_failed
  defp observe_exit(73), do: :io_failed
  defp observe_exit(75), do: :io_failed
  defp observe_exit(76), do: :unsupported_platform
  defp observe_exit(126), do: :launcher_unavailable
  defp observe_exit(_status), do: :io_failed

  defp parse_success(<<>>, _op), do: {:error, :output_empty}

  defp parse_success(output, operation) when is_binary(output) do
    lines = String.split(output, "\n")
    expected = expected_count(operation)
    needed = 3 + expected * 10

    case lines do
      ["g5b1-1", op_text | rest] ->
        with {:ok, ^operation} <- parse_operation(op_text) do
          if length(Enum.reject(lines, &(&1 == ""))) < needed do
            {:error, :output_incomplete}
          else
            with [count_text | fields] <- rest,
                 {:ok, ^expected} <- parse_uint(count_text),
                 {:ok, identities, leftover} <- parse_identities(fields, expected, []) do
              if leftover_ok?(leftover) do
                {:ok, success_result(operation, identities)}
              else
                {:error, :output_unparseable}
              end
            else
              _other -> {:error, :output_unparseable}
            end
          end
        else
          _other -> {:error, :output_unparseable}
        end

      _other ->
        {:error, :output_unparseable}
    end
  end

  defp leftover_ok?([]), do: true
  defp leftover_ok?([""]), do: true
  defp leftover_ok?(_other), do: false

  defp expected_count(:relocate), do: 4
  defp expected_count(_op), do: 3

  defp parse_operation("observe"), do: {:ok, :observe}
  defp parse_operation("stage"), do: {:ok, :stage}
  defp parse_operation("relocate"), do: {:ok, :relocate}
  defp parse_operation(_other), do: :error

  defp parse_identities(fields, 0, acc), do: {:ok, Enum.reverse(acc), fields}

  defp parse_identities(
         [path, type_text, mode, uid, gid, size, nlink, device, minor, inode | rest],
         remaining,
         acc
       ) do
    with {:ok, type} <- parse_type(type_text),
         {:ok, mode} <- parse_uint(mode),
         {:ok, uid} <- parse_uint(uid),
         {:ok, gid} <- parse_uint(gid),
         {:ok, size} <- parse_uint(size),
         {:ok, nlink} <- parse_uint(nlink),
         {:ok, device} <- parse_uint(device),
         {:ok, minor} <- parse_uint(minor),
         {:ok, inode} <- parse_uint(inode),
         true <- is_binary(path) and path != "" do
      identity = %{
        path: path,
        type: type,
        mode: mode,
        uid: uid,
        gid: gid,
        size: size,
        nlink: nlink,
        device: device,
        minor_device: minor,
        inode: inode
      }

      if MapSet.new(Map.keys(identity)) == MapSet.new(@identity_keys) do
        parse_identities(rest, remaining - 1, [identity | acc])
      else
        :error
      end
    else
      _other -> :error
    end
  end

  defp parse_identities(_fields, _remaining, _acc), do: :error

  defp parse_type("directory"), do: {:ok, :directory}
  defp parse_type("regular"), do: {:ok, :regular}
  defp parse_type(_other), do: :error

  defp parse_uint(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 0 -> {:ok, n}
      _other -> :error
    end
  end

  defp parse_uint(_text), do: :error

  defp success_result(:relocate, [root, parent, leaf, source_parent]) do
    %{
      operation: :relocate,
      root: root,
      parent: parent,
      leaf: leaf,
      source_parent: source_parent
    }
  end

  defp success_result(operation, [root, parent, leaf]) do
    %{operation: operation, root: root, parent: parent, leaf: leaf}
  end

  defp parse_retained(output) do
    case String.split(output, "\n") do
      ["g5b1-retained", reason_text] -> parse_retained_reason(reason_text)
      ["g5b1-retained", reason_text, ""] -> parse_retained_reason(reason_text)
      _other -> :error
    end
  end

  defp parse_retained_reason(text) do
    case Map.fetch(@native_retained, text) do
      {:ok, reason} -> {:ok, reason}
      :error -> :error
    end
  end

  defp close_port(port) do
    if Port.info(port) != nil do
      try do
        Port.close(port)
      catch
        :error, _reason -> :ok
      end
    end

    receive do
      {^port, {:exit_status, _status}} -> :ok
      {^port, {:data, _data}} -> close_port(port)
    after
      100 -> :ok
    end
  end
end

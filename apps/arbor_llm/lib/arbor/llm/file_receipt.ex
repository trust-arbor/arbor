defmodule Arbor.LLM.FileReceipt do
  @moduledoc false

  alias Arbor.LLM.Deadline

  @hard_maximum 16_777_216
  @maximum_path_bytes 4_096
  @read_timeout_ms 500
  @helper "/usr/bin/perl"
  @helper_script ~S"""
  use strict;
  use Fcntl qw(O_RDONLY O_NONBLOCK O_NOFOLLOW S_ISREG SEEK_SET);
  my ($path, $max) = @ARGV;
  sub fail_with { print "E\t$_[0]\n"; exit 0; }
  sub same_file {
    my ($a, $b) = @_;
    return $a->[0] == $b->[0] && $a->[1] == $b->[1] &&
           (($a->[2] & 0170000) == ($b->[2] & 0170000));
  }
  sub read_bounded {
    my ($fh, $max) = @_;
    my $body = "";
    while (1) {
      my $remaining = $max + 1 - length($body);
      my $read = sysread($fh, my $chunk, $remaining);
      defined($read) or fail_with("READ");
      last if $read == 0;
      $body .= $chunk;
      fail_with("TOO_LARGE") if length($body) > $max;
    }
    return $body;
  }
  my @path_before = lstat($path);
  @path_before or fail_with("LSTAT");
  S_ISREG($path_before[2]) or fail_with("NOT_REGULAR");
  sysopen(my $fh, $path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) or fail_with("OPEN");
  my @fd_before = stat($fh);
  @fd_before or fail_with("FSTAT");
  S_ISREG($fd_before[2]) or fail_with("NOT_REGULAR");
  same_file(\@path_before, \@fd_before) or fail_with("CHANGED");
  binmode($fh);
  my $first = read_bounded($fh, $max);
  sysseek($fh, 0, SEEK_SET) == 0 or fail_with("SEEK");
  my $second = read_bounded($fh, $max);
  $first eq $second or fail_with("CHANGED");
  my @fd_after = stat($fh);
  my @path_after = lstat($path);
  (@fd_after && @path_after && S_ISREG($fd_after[2]) && S_ISREG($path_after[2]))
    or fail_with("CHANGED");
  same_file(\@fd_before, \@fd_after) && same_file(\@fd_after, \@path_after)
    or fail_with("CHANGED");
  ($fd_before[7] == $fd_after[7] && $fd_before[9] == $fd_after[9] &&
   $fd_before[10] == $fd_after[10]) or fail_with("CHANGED");
  print "O\n", $second;
  """

  @spec read(term(), term()) :: {:ok, binary()} | {:error, term()}
  def read(path, maximum)
      when is_binary(path) and byte_size(path) <= @maximum_path_bytes and
             is_integer(maximum) and maximum > 0 do
    maximum = min(maximum, @hard_maximum)

    with true <- String.valid?(path) or {:error, :valid_utf8_path_required},
         {:ok, expected} <- path_identity(path),
         true <- expected.size <= maximum or {:error, {:file_bytes_exceeded, maximum}},
         {:ok, receipt} <- Deadline.receipt(timeout_ms: @read_timeout_ms) do
      Deadline.run(
        fn -> do_read(path, maximum, expected) end,
        receipt,
        :file_read_deadline_exceeded
      )
    end
  end

  def read(_path, _maximum), do: {:error, :bounded_regular_file_request_required}

  defp do_read(path, maximum, expected) do
    if File.regular?(@helper) do
      read_with_helper(path, maximum)
    else
      read_with_otp(path, maximum, expected)
    end
  end

  defp read_with_helper(path, maximum) do
    port =
      Port.open(
        {:spawn_executable, @helper},
        [
          :binary,
          :use_stdio,
          :stderr_to_stdout,
          :exit_status,
          args: ["-e", @helper_script, "--", path, Integer.to_string(maximum)]
        ]
      )

    monitor = :erlang.monitor(:port, port)
    collect_helper(port, monitor, maximum, [], 0)
  rescue
    _exception -> {:error, :file_open_failed}
  end

  defp collect_helper(port, monitor, maximum, chunks, retained) do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        next = retained + byte_size(data)

        if next <= maximum + 4_096,
          do: collect_helper(port, monitor, maximum, [data | chunks], next),
          else: close_port(port, monitor, {:error, {:file_bytes_exceeded, maximum}})

      {^port, {:exit_status, 0}} ->
        await_port_down(port, monitor)
        chunks |> Enum.reverse() |> IO.iodata_to_binary() |> parse_helper(maximum)

      {^port, {:exit_status, _status}} ->
        await_port_down(port, monitor)
        {:error, :file_open_failed}
    end
  end

  defp close_port(port, monitor, result) do
    if Port.info(port), do: Port.close(port)
    await_port_down(port, monitor)
    result
  catch
    :error, :badarg ->
      await_port_down(port, monitor)
      result
  end

  defp await_port_down(port, monitor) do
    receive do
      {:DOWN, ^monitor, :port, ^port, _reason} -> :ok
      {^port, {:exit_status, _status}} -> await_port_down(port, monitor)
    end
  end

  defp parse_helper("O\n" <> body, maximum) when byte_size(body) <= maximum, do: {:ok, body}
  defp parse_helper("E\tTOO_LARGE\n", maximum), do: {:error, {:file_bytes_exceeded, maximum}}
  defp parse_helper("E\tNOT_REGULAR\n", _maximum), do: {:error, :not_regular_file}
  defp parse_helper("E\tCHANGED\n", _maximum), do: {:error, :file_changed_during_read}
  defp parse_helper("E\tOPEN\n", _maximum), do: {:error, :file_open_failed}
  defp parse_helper("E\t" <> _reason, _maximum), do: {:error, :file_read_failed}
  defp parse_helper(_other, _maximum), do: {:error, :invalid_file_helper_response}

  defp read_with_otp(path, maximum, expected) do
    case File.open(path, [:read, :binary, :raw], fn io ->
           with {:ok, ^expected} <- descriptor_identity(io),
                {:ok, first} <- read_bounded(io, maximum),
                true <- byte_size(first) == expected.size or {:error, :file_changed_during_read},
                {:ok, 0} <- :file.position(io, 0),
                {:ok, second} <- read_bounded(io, maximum),
                true <- byte_size(second) == expected.size or {:error, :file_changed_during_read},
                true <- secure_equal(first, second) or {:error, :file_changed_during_read},
                {:ok, ^expected} <- descriptor_identity(io),
                {:ok, ^expected} <- path_identity(path) do
             {:ok, second}
           else
             {:ok, _changed} -> {:error, :file_changed_during_read}
             {:error, _reason} = error -> error
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:file_open_failed, reason}}
    end
  end

  defp read_bounded(io, maximum), do: read_bounded(io, maximum, [], 0)

  defp read_bounded(io, maximum, chunks, retained) do
    to_read = min(65_536, maximum - retained + 1)

    case :file.read(io, to_read) do
      :eof ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, body} when retained + byte_size(body) <= maximum ->
        read_bounded(io, maximum, [body | chunks], retained + byte_size(body))

      {:ok, _body} ->
        {:error, {:file_bytes_exceeded, maximum}}

      {:error, reason} ->
        {:error, {:file_read_failed, reason}}
    end
  end

  defp secure_equal(left, right) when byte_size(left) == byte_size(right) do
    :crypto.hash(:sha256, left) == :crypto.hash(:sha256, right)
  end

  defp secure_equal(_left, _right), do: false

  defp path_identity(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, identity(stat)}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular_file, type}}
      {:error, reason} -> {:error, {:file_stat_failed, reason}}
    end
  end

  defp descriptor_identity(io) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, info} ->
        case File.Stat.from_record(info) do
          %File.Stat{type: :regular} = stat -> {:ok, identity(stat)}
          %File.Stat{type: type} -> {:error, {:not_regular_file, type}}
        end

      {:error, reason} ->
        {:error, {:file_stat_failed, reason}}
    end
  end

  defp identity(stat) do
    %{
      type: stat.type,
      inode: stat.inode,
      major_device: stat.major_device,
      minor_device: stat.minor_device,
      size: stat.size,
      mtime: stat.mtime,
      ctime: stat.ctime
    }
  end
end

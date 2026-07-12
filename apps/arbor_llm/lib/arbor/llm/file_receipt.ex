defmodule Arbor.LLM.FileReceipt do
  @moduledoc false

  alias Arbor.LLM.Deadline

  @hard_maximum 16_777_216
  @maximum_path_bytes 4_096
  @read_timeout_ms 500
  @write_timeout_ms 5_000
  @helper "/usr/bin/perl"
  @publish_helper "/usr/bin/python3"
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
  sub one_link { return $_[0]->[3] == 1; }
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
  one_link(\@path_before) or fail_with("HARDLINK");
  sysopen(my $fh, $path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) or fail_with("OPEN");
  my @fd_before = stat($fh);
  @fd_before or fail_with("FSTAT");
  S_ISREG($fd_before[2]) or fail_with("NOT_REGULAR");
  one_link(\@fd_before) or fail_with("HARDLINK");
  same_file(\@path_before, \@fd_before) or fail_with("CHANGED");
  binmode($fh);
  my $first = read_bounded($fh, $max);
  sysseek($fh, 0, SEEK_SET) == 0 or fail_with("SEEK");
  my $second = read_bounded($fh, $max);
  $first eq $second or fail_with("CHANGED");
  my @fd_after = stat($fh);
  my @path_after = lstat($path);
  (@fd_after && @path_after && S_ISREG($fd_after[2]) && S_ISREG($path_after[2]) &&
   one_link(\@fd_after) && one_link(\@path_after))
    or fail_with("CHANGED");
  same_file(\@fd_before, \@fd_after) && same_file(\@fd_after, \@path_after)
    or fail_with("CHANGED");
  ($fd_before[7] == $fd_after[7] && $fd_before[9] == $fd_after[9] &&
   $fd_before[10] == $fd_after[10]) or fail_with("CHANGED");
  print "O\n", $second;
  """
  @publish_python_script ~S"""
  import errno
  import os
  import stat
  import sys

  root, name, length_text, maximum_text, stage_name = sys.argv[1:]
  length = int(length_text)
  maximum = int(maximum_text)
  dir_fd = None
  stage_fd = None
  stage_exists = False

  class PublishError(Exception):
      pass

  def fail(label):
      raise PublishError(label)

  def same_file(left, right):
      return (left.st_dev == right.st_dev and left.st_ino == right.st_ino and
              stat.S_IFMT(left.st_mode) == stat.S_IFMT(right.st_mode))

  def stat_at(entry):
      return os.stat(entry, dir_fd=dir_fd, follow_symlinks=False)

  try:
      if length < 0 or length > maximum:
          fail("TOO_LARGE")
      if not name or "/" in name or name in (".", ".."):
          fail("NAME")
      if not stage_name.startswith(".arbor-fixture-") or not stage_name.endswith(".tmp"):
          fail("NAME")

      root_before = os.lstat(root)
      if not stat.S_ISDIR(root_before.st_mode):
          fail("ROOT_NOT_DIRECTORY")

      dir_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
      root_fd = os.fstat(dir_fd)
      if not stat.S_ISDIR(root_fd.st_mode) or not same_file(root_before, root_fd):
          fail("ROOT_OPEN_CHANGED")

      try:
          final_before = stat_at(name)
          final_existed = True
          if not stat.S_ISREG(final_before.st_mode):
              fail("DEST_NOT_REGULAR")
          if final_before.st_nlink != 1:
              fail("DEST_HARDLINK")
      except FileNotFoundError:
          final_before = None
          final_existed = False

      stage_fd = os.open(
          stage_name,
          os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
          0o600,
          dir_fd=dir_fd,
      )
      stage_exists = True
      stage_before = os.fstat(stage_fd)
      if not stat.S_ISREG(stage_before.st_mode) or stage_before.st_nlink != 1:
          fail("STAGE_CHANGED")

      retained = 0
      source = sys.stdin.buffer
      while retained < length:
          chunk = source.read(min(65536, length - retained))
          if not chunk:
              fail("INPUT")
          retained += len(chunk)
          if retained > maximum:
              fail("TOO_LARGE")
          offset = 0
          while offset < len(chunk):
              written = os.write(stage_fd, chunk[offset:])
              if written <= 0:
                  fail("WRITE")
              offset += written

      os.fsync(stage_fd)
      os.close(stage_fd)
      stage_fd = None

      stage_path_stat = stat_at(stage_name)
      if (not stat.S_ISREG(stage_path_stat.st_mode) or stage_path_stat.st_nlink != 1 or
              not same_file(stage_before, stage_path_stat)):
          fail("STAGE_CHANGED")

      root_now = os.lstat(root)
      if not stat.S_ISDIR(root_now.st_mode) or not same_file(root_fd, root_now):
          fail("ROOT_PREPUBLISH_CHANGED")

      try:
          final_now = stat_at(name)
          now_exists = True
      except FileNotFoundError:
          final_now = None
          now_exists = False

      if final_existed:
          if (not now_exists or not stat.S_ISREG(final_now.st_mode) or
                  final_now.st_nlink != 1 or not same_file(final_before, final_now)):
              fail("DEST_CHANGED")
      elif now_exists:
          fail("DEST_CHANGED")

      os.replace(stage_name, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
      stage_exists = False
      final_after = stat_at(name)
      if (not stat.S_ISREG(final_after.st_mode) or final_after.st_nlink != 1 or
              not same_file(stage_before, final_after)):
          fail("PUBLISH_CHANGED")

      root_after = os.lstat(root)
      if not stat.S_ISDIR(root_after.st_mode) or not same_file(root_fd, root_after):
          fail("ROOT_POSTPUBLISH_CHANGED")

      os.fsync(dir_fd)
      sys.stdout.write("O\n")
  except PublishError as error:
      sys.stdout.write("E\t" + str(error) + "\n")
  except FileNotFoundError:
      sys.stdout.write("E\tCHANGED\n")
  except OSError:
      sys.stdout.write("E\tWRITE\n")
  except BaseException:
      sys.stdout.write("E\tWRITE\n")
  finally:
      if stage_fd is not None:
          try:
              os.close(stage_fd)
          except OSError:
              pass
      if stage_exists and dir_fd is not None:
          try:
              os.unlink(stage_name, dir_fd=dir_fd)
          except OSError:
              pass
      if dir_fd is not None:
          try:
              os.close(dir_fd)
          except OSError:
              pass
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

  @spec publish(term(), term(), term()) :: :ok | {:error, term()}
  def publish(path, body, maximum)
      when is_binary(path) and byte_size(path) <= @maximum_path_bytes and is_binary(body) and
             is_integer(maximum) and maximum > 0 do
    maximum = min(maximum, @hard_maximum)

    with true <- String.valid?(path) or {:error, :valid_utf8_path_required},
         true <- byte_size(body) <= maximum or {:error, {:file_bytes_exceeded, maximum}},
         :ok <- ensure_publish_root(Path.dirname(path)),
         {:ok, receipt} <- Deadline.receipt(timeout_ms: @write_timeout_ms) do
      Deadline.run(
        fn -> do_publish(path, body, maximum) end,
        receipt,
        :file_write_deadline_exceeded
      )
    end
  end

  def publish(_path, _body, _maximum), do: {:error, :bounded_regular_file_write_required}

  defp do_read(path, maximum, expected) do
    if File.regular?(@helper) do
      read_with_helper(path, maximum)
    else
      read_with_otp(path, maximum, expected)
    end
  end

  defp do_publish(path, body, maximum) do
    if File.regular?(@publish_helper) do
      with :ok <- publish_with_helper(path, body, maximum),
           {:ok, written} <- read(path, maximum),
           true <- secure_equal(body, written) or {:error, :published_file_changed} do
        :ok
      end
    else
      {:error, :secure_publication_unavailable}
    end
  end

  defp ensure_publish_root(root) do
    with :ok <- File.mkdir_p(root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(root) do
      :ok
    else
      {:ok, %File.Stat{type: :symlink}} -> {:error, :fixture_root_symlink_rejected}
      {:ok, %File.Stat{type: type}} -> {:error, {:fixture_root_not_directory, type}}
      {:error, reason} -> {:error, {:fixture_root_failed, reason}}
    end
  end

  defp publish_with_helper(path, body, maximum) do
    root = Path.dirname(path)
    name = Path.basename(path)
    stage_name = ".arbor-fixture-" <> Base.encode16(:crypto.strong_rand_bytes(16)) <> ".tmp"

    port =
      Port.open(
        {:spawn_executable, @publish_helper},
        [
          :binary,
          :use_stdio,
          :stderr_to_stdout,
          :exit_status,
          args: [
            "-c",
            @publish_python_script,
            root,
            name,
            Integer.to_string(byte_size(body)),
            Integer.to_string(maximum),
            stage_name
          ]
        ]
      )

    monitor = :erlang.monitor(:port, port)

    if Port.command(port, body) do
      collect_publish_helper(port, monitor, [], 0)
    else
      close_port(port, monitor, {:error, :file_write_failed})
    end
  rescue
    _exception -> {:error, :file_open_failed}
  catch
    _kind, _reason -> {:error, :file_open_failed}
  end

  defp collect_publish_helper(port, monitor, chunks, retained) do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        next = retained + byte_size(data)

        if next <= 4_096,
          do: collect_publish_helper(port, monitor, [data | chunks], next),
          else: close_port(port, monitor, {:error, :invalid_file_helper_response})

      {^port, {:exit_status, 0}} ->
        await_port_down(port, monitor)
        chunks |> Enum.reverse() |> IO.iodata_to_binary() |> parse_publish_helper()

      {^port, {:exit_status, _status}} ->
        await_port_down(port, monitor)
        {:error, :file_write_failed}
    end
  end

  defp parse_publish_helper("O\n"), do: :ok
  defp parse_publish_helper("E\tDEST_HARDLINK\n"), do: {:error, :hardlink_rejected}
  defp parse_publish_helper("E\tDEST_NOT_REGULAR\n"), do: {:error, :not_regular_file}
  defp parse_publish_helper("E\tROOT_NOT_DIRECTORY\n"), do: {:error, :not_directory}

  defp parse_publish_helper("E\tROOT_OPEN_CHANGED\n"), do: {:error, :fixture_root_open_changed}
  defp parse_publish_helper("E\tROOT_FD_CHANGED\n"), do: {:error, :fixture_root_fd_changed}

  defp parse_publish_helper("E\tROOT_PREPUBLISH_CHANGED\n"),
    do: {:error, :fixture_root_prepublish_changed}

  defp parse_publish_helper("E\tROOT_POSTPUBLISH_CHANGED\n"),
    do: {:error, :fixture_root_postpublish_changed}

  defp parse_publish_helper("E\tDEST_CHANGED\n"), do: {:error, :destination_changed}
  defp parse_publish_helper("E\tPUBLISH_CHANGED\n"), do: {:error, :publication_changed}

  defp parse_publish_helper("E\tTOO_LARGE\n"), do: {:error, :file_too_large}
  defp parse_publish_helper("E\t" <> _reason), do: {:error, :file_write_failed}
  defp parse_publish_helper(_other), do: {:error, :invalid_file_helper_response}

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
  defp parse_helper("E\tHARDLINK\n", _maximum), do: {:error, :hardlink_rejected}
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
      {:ok, %File.Stat{type: :regular, links: 1} = stat} -> {:ok, identity(stat)}
      {:ok, %File.Stat{type: :regular}} -> {:error, :hardlink_rejected}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular_file, type}}
      {:error, reason} -> {:error, {:file_stat_failed, reason}}
    end
  end

  defp descriptor_identity(io) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, info} ->
        case File.Stat.from_record(info) do
          %File.Stat{type: :regular, links: 1} = stat -> {:ok, identity(stat)}
          %File.Stat{type: :regular} -> {:error, :hardlink_rejected}
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
      ctime: stat.ctime,
      links: stat.links
    }
  end
end

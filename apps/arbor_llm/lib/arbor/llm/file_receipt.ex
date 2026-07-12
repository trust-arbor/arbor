defmodule Arbor.LLM.FileReceipt do
  @moduledoc false

  alias Arbor.LLM.Deadline

  @hard_maximum 16_777_216
  @maximum_path_bytes 4_096
  @read_timeout_ms 500
  @write_timeout_ms 5_000
  @cleanup_grace_ms 250
  @stage_attempts 8
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
    with {:ok, receipt} <- Deadline.receipt(timeout_ms: @write_timeout_ms) do
      publish(path, body, maximum, receipt)
    end
  end

  def publish(_path, _body, _maximum), do: {:error, :bounded_regular_file_write_required}

  @doc false
  @spec publish(term(), term(), term(), Deadline.receipt()) :: :ok | {:error, term()}
  def publish(path, body, maximum, %{deadline_ms: deadline_ms, timeout_ms: timeout_ms})
      when is_binary(path) and byte_size(path) <= @maximum_path_bytes and is_binary(body) and
             is_integer(maximum) and maximum > 0 and is_integer(deadline_ms) and
             is_integer(timeout_ms) and timeout_ms > 0 do
    maximum = min(maximum, @hard_maximum)
    root = Path.dirname(path)

    with true <- String.valid?(path) or {:error, :valid_utf8_path_required},
         true <- byte_size(body) <= maximum or {:error, {:file_bytes_exceeded, maximum}},
         :ok <- ensure_publish_root(root),
         :ok <- validate_directory_chain(root),
         {:ok, receipt} <-
           Deadline.receipt_until(deadline_ms, min(timeout_ms, @write_timeout_ms)),
         {:ok, directory, root_identity} <- open_directory(root) do
      try do
        publish_attempt(path, body, maximum, receipt, directory, root_identity, @stage_attempts)
      after
        :file.close(directory)
      end
    end
  end

  def publish(_path, _body, _maximum, _receipt),
    do: {:error, :bounded_regular_file_write_required}

  defp do_read(path, maximum, expected) do
    if File.regular?(@helper) do
      read_with_helper(path, maximum)
    else
      read_with_otp(path, maximum, expected)
    end
  end

  defp publish_attempt(_path, _body, _maximum, _receipt, _directory, _root_identity, 0),
    do: {:error, :fixture_stage_collision}

  defp publish_attempt(path, body, maximum, receipt, directory, root_identity, attempts) do
    root = Path.dirname(path)
    stage = Path.join(root, stage_name())

    with :ok <- ensure_root_stable(root, directory, root_identity),
         :ok <- ensure_destination_absent(path) do
      result =
        Deadline.run(
          fn -> do_publish(path, stage, body, maximum, root_identity) end,
          receipt,
          :file_write_deadline_exceeded
        )

      case reconcile_publication(result, path, stage, body, directory, root_identity) do
        {:retry, :stage_collision} ->
          publish_attempt(
            path,
            body,
            maximum,
            receipt,
            directory,
            root_identity,
            attempts - 1
          )

        final ->
          final
      end
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

  defp do_publish(path, stage, body, maximum, root_identity) do
    root = Path.dirname(path)

    with true <- byte_size(body) <= maximum or {:error, :file_too_large},
         :ok <- validate_directory_chain(root),
         {:ok, directory, ^root_identity} <- open_directory(root) do
      try do
        with :ok <- ensure_root_stable(root, directory, root_identity),
             :ok <- ensure_destination_absent(path),
             {:ok, stage_identity} <- write_stage(stage, body),
             :ok <- ensure_root_stable(root, directory, root_identity),
             {:ok, stage_path_identity} <- regular_path_identity(stage, [1]),
             true <-
               same_file?(stage_identity, stage_path_identity) or
                 {:error, :fixture_stage_changed},
             :ok <- ensure_destination_absent(path),
             :ok <- File.ln(stage, path),
             {:ok, linked_stage} <- regular_path_identity(stage, [2]),
             {:ok, linked_final} <- regular_path_identity(path, [2]),
             true <-
               same_file?(stage_identity, linked_stage) or
                 {:error, :fixture_stage_changed},
             true <-
               same_file?(linked_stage, linked_final) or
                 {:error, :fixture_publication_changed},
             :ok <- File.rm(stage),
             {:ok, final_identity} <- regular_path_identity(path, [1]),
             true <-
               same_file?(stage_identity, final_identity) or
                 {:error, :fixture_publication_changed},
             true <-
               final_identity.size == byte_size(body) or
                 {:error, :fixture_publication_changed},
             :ok <- ensure_root_stable(root, directory, root_identity),
             :ok <- :file.sync(directory) do
          :ok
        else
          {:error, :eexist} -> {:error, :destination_changed}
          {:error, reason} -> {:error, reason}
          false -> {:error, :fixture_publication_changed}
        end
      after
        :file.close(directory)
      end
    else
      {:ok, changed_directory, _changed_identity} ->
        :file.close(changed_directory)
        {:error, :fixture_root_open_changed}

      {:error, reason} ->
        {:error, reason}

      false ->
        {:error, :file_too_large}
    end
  end

  defp write_stage(stage, body) do
    case File.open(stage, [:write, :binary, :raw, :exclusive], fn io ->
           with :ok <- File.chmod(stage, 0o600),
                {:ok, before} <- descriptor_identity(io),
                :ok <- :file.write(io, body),
                :ok <- :file.sync(io),
                {:ok, after_write} <- descriptor_identity(io),
                true <- same_file?(before, after_write) or {:error, :fixture_stage_changed},
                true <-
                  after_write.size == byte_size(body) or
                    {:error, :fixture_stage_changed} do
             {:ok, after_write}
           else
             {:error, reason} -> {:error, reason}
             false -> {:error, :fixture_stage_changed}
           end
         end) do
      {:ok, {:ok, identity}} -> {:ok, identity}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :eexist} -> {:error, :stage_collision}
      {:error, reason} -> {:error, {:fixture_stage_open_failed, reason}}
    end
  end

  defp reconcile_publication(:ok, path, stage, _body, directory, root_identity) do
    with :ok <- ensure_root_stable(Path.dirname(path), directory, root_identity),
         {:error, {:file_stat_failed, :enoent}} <- path_identity(stage),
         {:ok, _final} <- path_identity(path),
         :ok <- :file.sync(directory) do
      :ok
    else
      {:ok, _unexpected_stage} -> {:error, :fixture_stage_cleanup_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_publication(
         {:error, :stage_collision},
         _path,
         _stage,
         _body,
         _directory,
         _root_identity
       ),
       do: {:retry, :stage_collision}

  defp reconcile_publication(result, path, stage, body, directory, root_identity) do
    cleanup_result =
      reconcile_failed_publication(path, stage, body, directory, root_identity)

    case cleanup_result do
      :ok -> result
      {:error, reason} -> {:error, {:fixture_publication_reconciliation_failed, reason}}
    end
  end

  defp reconcile_failed_publication(path, stage, body, directory, root_identity) do
    root = Path.dirname(path)
    deadline = System.monotonic_time(:millisecond) + @cleanup_grace_ms

    with :ok <- await_root_stable(root, directory, root_identity, deadline),
         :ok <- remove_failed_final(path, stage, body),
         :ok <- remove_stage(stage),
         :ok <- ensure_root_stable(root, directory, root_identity),
         :ok <- :file.sync(directory) do
      :ok
    end
  end

  defp remove_failed_final(path, stage, body) do
    stage_identity = any_regular_path_identity(stage)
    final_identity = any_regular_path_identity(path)

    cond do
      match?({:ok, _}, stage_identity) and match?({:ok, _}, final_identity) ->
        {:ok, staged} = stage_identity
        {:ok, final} = final_identity

        if same_file?(staged, final), do: remove_path(path), else: :ok

      match?({:ok, _}, final_identity) ->
        {:ok, final} = final_identity

        if final.size == byte_size(body) do
          case File.read(path) do
            {:ok, written} ->
              if secure_equal(written, body), do: remove_path(path), else: :ok

            _other ->
              :ok
          end
        else
          :ok
        end

      true ->
        :ok
    end
  end

  defp remove_stage(stage) do
    case File.lstat(stage) do
      {:ok, _stat} -> remove_path(stage)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:fixture_stage_stat_failed, reason}}
    end
  end

  defp remove_path(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:fixture_cleanup_failed, reason}}
    end
  end

  defp ensure_destination_absent(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular, links: links}} when links != 1 ->
        {:error, :hardlink_rejected}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :destination_exists}

      {:ok, %File.Stat{type: _type}} ->
        {:error, :not_regular_file}

      {:error, reason} ->
        {:error, {:destination_stat_failed, reason}}
    end
  end

  defp stage_name do
    ".arbor-fixture-" <>
      Base.encode16(:crypto.strong_rand_bytes(16), case: :lower) <> ".tmp"
  end

  defp validate_directory_chain(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce_while(nil, fn component, current ->
      current = if is_nil(current), do: component, else: Path.join(current, component)

      case File.lstat(current) do
        {:ok, %File.Stat{type: :directory}} ->
          {:cont, current}

        # Platform roots such as /var may be stable symlinks. The opened root
        # descriptor and repeated root identity checks still detect replacement
        # of the resolved operator directory.
        {:ok, %File.Stat{type: :symlink}} ->
          {:cont, current}

        {:ok, %File.Stat{type: type}} ->
          {:halt, {:error, {:fixture_ancestor_not_directory, type}}}

        {:error, reason} ->
          {:halt, {:error, {:fixture_ancestor_stat_failed, reason}}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      _path -> :ok
    end
  end

  defp open_directory(root) do
    with {:ok, path_identity} <- directory_path_identity(root) do
      case :file.open(String.to_charlist(root), [:read, :raw, :directory]) do
        {:ok, directory} ->
          case directory_descriptor_identity(directory) do
            {:ok, descriptor_identity} when path_identity == descriptor_identity ->
              {:ok, directory, descriptor_identity}

            {:ok, _changed_identity} ->
              :file.close(directory)
              {:error, :fixture_root_open_changed}

            {:error, reason} ->
              :file.close(directory)
              {:error, {:fixture_root_open_failed, reason}}
          end

        {:error, reason} ->
          {:error, {:fixture_root_open_failed, reason}}
      end
    else
      {:error, reason} -> {:error, {:fixture_root_open_failed, reason}}
    end
  end

  defp ensure_root_stable(root, directory, expected) do
    with {:ok, ^expected} <- directory_descriptor_identity(directory),
         {:ok, ^expected} <- directory_path_identity(root),
         :ok <- validate_directory_chain(root) do
      :ok
    else
      {:ok, _changed} -> {:error, :fixture_root_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_root_stable(root, directory, expected, deadline) do
    case ensure_root_stable(root, directory, expected) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1)
          await_root_stable(root, directory, expected, deadline)
        else
          error
        end
    end
  end

  defp directory_path_identity(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} -> {:ok, stable_identity(stat)}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :fixture_root_symlink_rejected}
      {:ok, %File.Stat{type: type}} -> {:error, {:fixture_root_not_directory, type}}
      {:error, reason} -> {:error, {:fixture_root_stat_failed, reason}}
    end
  end

  defp directory_descriptor_identity(io) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, info} ->
        case File.Stat.from_record(info) do
          %File.Stat{type: :directory} = stat -> {:ok, stable_identity(stat)}
          %File.Stat{type: type} -> {:error, {:fixture_root_not_directory, type}}
        end

      {:error, reason} ->
        {:error, {:fixture_root_descriptor_failed, reason}}
    end
  end

  defp regular_path_identity(path, allowed_links) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, links: links} = stat} ->
        if links in allowed_links,
          do: {:ok, identity(stat)},
          else: {:error, :fixture_link_count_changed}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_rejected}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:not_regular_file, type}}

      {:error, reason} ->
        {:error, {:file_stat_failed, reason}}
    end
  end

  defp any_regular_path_identity(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, identity(stat)}
      _missing_or_invalid -> :error
    end
  end

  defp same_file?(left, right), do: stable_identity(left) == stable_identity(right)

  defp stable_identity(%File.Stat{} = stat) do
    %{
      type: stat.type,
      inode: stat.inode,
      major_device: stat.major_device,
      minor_device: stat.minor_device
    }
  end

  defp stable_identity(identity) when is_map(identity) do
    Map.take(identity, [:type, :inode, :major_device, :minor_device])
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

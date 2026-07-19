defmodule Arbor.Commands.CodingBenchmark.Git do
  @moduledoc false

  @max_output_bytes 65_536
  @max_configured_output_bytes 268_435_456
  @shell_output_ceiling 16_777_216
  # Fixture trees are capped at 10_000 entries; allow commit + root-tree additions.
  @max_fixture_entries 10_000
  @max_object_requests @max_fixture_entries + 2
  # Defense-in-depth: every cat-file process stays cardinality-bounded even when
  # wire/output budgets would otherwise admit unbounded zero-byte batches.
  @max_cat_file_batch_objects 64
  @max_diagnostic_bytes 500
  @oid_pattern ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @allowed_object_types MapSet.new(["blob", "tree", "commit"])
  @batch_check_line_overhead 96
  @neutral_config [
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.pager=cat",
    "-c",
    "pager.status=false",
    "-c",
    "commit.gpgSign=false"
  ]
  @neutral_env %{
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_NO_LAZY_FETCH" => "1",
    "GIT_NO_REPLACE_OBJECTS" => "1",
    "GIT_TERMINAL_PROMPT" => "0",
    "LC_ALL" => "C"
  }

  @type timeout_spec :: pos_integer() | {:deadline, integer()}
  @type object_request :: %{required(:oid) => String.t(), required(:type) => String.t()}
  @type object_spec :: %{
          required(:oid) => String.t(),
          required(:type) => String.t(),
          required(:size) => non_neg_integer()
        }
  @type object_payload :: %{
          required(:type) => String.t(),
          required(:size) => non_neg_integer(),
          required(:content) => binary()
        }

  @doc false
  @spec deadline(pos_integer()) :: {:deadline, integer()}
  def deadline(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    {:deadline, System.monotonic_time(:millisecond) + timeout_ms}
  end

  @spec run(String.t(), [String.t()], timeout_spec(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(workdir, args, timeout_ms, opts \\ [])

  def run(workdir, args, timeout, opts) when is_binary(workdir) and is_list(args) do
    max_output_bytes = Keyword.get(opts, :max_output_bytes, @max_output_bytes)

    with {:ok, timeout_ms} <- remaining_timeout(timeout),
         true <-
           is_integer(max_output_bytes) and max_output_bytes > 0 and
             max_output_bytes <= @max_configured_output_bytes do
      execute(
        ["--no-replace-objects", "-C", workdir] ++ @neutral_config ++ args,
        timeout_ms,
        max_output_bytes,
        nil
      )
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, "git_invalid_request"}
    end
  end

  def run(_workdir, _args, _timeout_ms, _opts), do: {:error, "git_invalid_request"}

  @doc """
  Read validated Git objects via closed `git cat-file` batch primitives.

  Accepts only 40/64-hex object IDs and closed types (`blob`, `tree`, `commit`).
  Sizes are discovered with `--batch-check`, then content is fetched in
  output-budgeted `--batch` groups (or single-object reads for oversized
  members). Each cat-file process is also capped at
  `max_cat_file_batch_objects/0` requests so stdin/metadata bursts stay bounded
  even for zero-byte objects. Each unique OID is returned once with
  independently owned content bytes.
  """
  @spec read_objects(String.t(), [object_request()], timeout_spec(), keyword()) ::
          {:ok, %{optional(String.t()) => object_payload()}} | {:error, String.t()}
  def read_objects(workdir, requests, timeout, opts \\ [])

  def read_objects(workdir, requests, timeout, opts)
      when is_binary(workdir) and is_list(requests) and is_list(opts) do
    max_object_bytes = Keyword.get(opts, :max_object_bytes, @shell_output_ceiling)
    max_total_bytes = Keyword.get(opts, :max_total_bytes, @max_configured_output_bytes)
    shell_ceiling = shell_output_ceiling()

    with :ok <- validate_object_request_count(requests),
         {:ok, normalized} <- normalize_object_requests(requests),
         :ok <- validate_object_request_count(normalized),
         true <-
           is_integer(max_object_bytes) and max_object_bytes > 0 and
             max_object_bytes <= @shell_output_ceiling and is_integer(max_total_bytes) and
             max_total_bytes > 0 and max_total_bytes <= @max_configured_output_bytes,
         {:ok, specs, check_process_count} <-
           batch_check_objects(workdir, normalized, timeout, max_object_bytes, max_total_bytes),
         {:ok, batches} <- partition_objects_for_batch(specs, shell_ceiling),
         {:ok, objects, fetch_process_count} <-
           fetch_object_batches(workdir, batches, timeout, shell_ceiling) do
      emit_object_batch_telemetry(
        length(specs),
        length(batches),
        check_process_count + fetch_process_count
      )

      {:ok, objects}
    else
      false -> {:error, "git_invalid_object_request"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, "git_invalid_object_request"}
    end
  end

  def read_objects(_workdir, _requests, _timeout, _opts),
    do: {:error, "git_invalid_object_request"}

  @doc false
  @spec max_object_requests() :: pos_integer()
  def max_object_requests, do: @max_object_requests

  @doc false
  @spec max_cat_file_batch_objects() :: pos_integer()
  def max_cat_file_batch_objects, do: @max_cat_file_batch_objects

  @doc false
  @spec normalize_object_requests(term()) ::
          {:ok, [object_request()]} | {:error, String.t()}
  def normalize_object_requests(requests) when is_list(requests) do
    with :ok <- validate_object_request_count(requests) do
      requests
      |> Enum.reduce_while({:ok, [], MapSet.new()}, fn request, {:ok, acc, seen} ->
        case normalize_object_request(request) do
          {:ok, %{oid: oid, type: type} = normalized} ->
            key = oid

            cond do
              MapSet.member?(seen, key) ->
                prior = Enum.find(acc, &(&1.oid == oid))

                if prior.type == type do
                  {:cont, {:ok, acc, seen}}
                else
                  {:halt, {:error, "git_object_type_conflict"}}
                end

              true ->
                {:cont, {:ok, [normalized | acc], MapSet.put(seen, key)}}
            end

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, acc, _seen} ->
          normalized = Enum.reverse(acc)

          with :ok <- validate_object_request_count(normalized) do
            {:ok, normalized}
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  def normalize_object_requests(_requests), do: {:error, "git_invalid_object_request"}

  @doc false
  @spec parse_batch_check_output(binary(), [object_request()]) ::
          {:ok, [object_spec()]} | {:error, String.t()}
  def parse_batch_check_output(output, requests)
      when is_binary(output) and is_list(requests) do
    with {:ok, lines} <- split_exact_lines(output) do
      if length(lines) != length(requests) do
        {:error, "git_batch_check_count_mismatch"}
      else
        requests
        |> Enum.zip(lines)
        |> Enum.reduce_while({:ok, []}, fn {request, line}, {:ok, acc} ->
          case parse_batch_check_line(line, request) do
            {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, specs} -> {:ok, Enum.reverse(specs)}
          error -> error
        end
      end
    end
  end

  def parse_batch_check_output(_output, _requests), do: {:error, "git_batch_check_malformed"}

  @doc false
  @spec bounded_diagnostic_output(term()) :: String.t()
  def bounded_diagnostic_output(output), do: bounded_output(output)

  @doc false
  @spec parse_batch_objects_output(binary(), [object_spec()]) ::
          {:ok, %{optional(String.t()) => object_payload()}} | {:error, String.t()}
  def parse_batch_objects_output(output, specs) when is_binary(output) and is_list(specs) do
    parse_batch_objects_output(output, specs, %{})
  end

  def parse_batch_objects_output(_output, _specs), do: {:error, "git_batch_payload_malformed"}

  @doc false
  @spec partition_objects_for_batch([object_spec()], pos_integer()) ::
          {:ok, [{:batch, [object_spec()]} | {:single, object_spec()}]} | {:error, String.t()}
  def partition_objects_for_batch(specs, max_output_bytes)
      when is_list(specs) and is_integer(max_output_bytes) and max_output_bytes > 0 do
    specs
    |> Enum.reduce_while({:ok, [], nil}, fn spec, {:ok, batches, current} ->
      cost = batch_object_wire_bytes(spec)

      cond do
        not valid_object_spec?(spec) ->
          {:halt, {:error, "git_invalid_object_spec"}}

        cost > max_output_bytes ->
          flushed = flush_batch(batches, current)
          {:cont, {:ok, [{:single, spec} | flushed], nil}}

        true ->
          case current do
            nil ->
              {:cont, {:ok, batches, {[spec], cost, 1}}}

            {group, used, count}
            when used + cost <= max_output_bytes and count < @max_cat_file_batch_objects ->
              {:cont, {:ok, batches, {[spec | group], used + cost, count + 1}}}

            {group, _used, _count} ->
              {:cont, {:ok, [{:batch, Enum.reverse(group)} | batches], {[spec], cost, 1}}}
          end
      end
    end)
    |> case do
      {:ok, batches, current} ->
        {:ok, batches |> flush_batch(current) |> Enum.reverse()}

      {:error, _reason} = error ->
        error
    end
  end

  def partition_objects_for_batch(_specs, _max_output_bytes),
    do: {:error, "git_invalid_object_request"}

  @doc false
  @spec partition_requests_for_check([object_request()], pos_integer()) ::
          {:ok, [[object_request()]]} | {:error, String.t()}
  def partition_requests_for_check(requests, shell_ceiling)
      when is_list(requests) and is_integer(shell_ceiling) and shell_ceiling > 0 do
    max_lines =
      shell_ceiling
      |> div(@batch_check_line_overhead)
      |> max(1)
      |> min(@max_cat_file_batch_objects)

    {:ok, Enum.chunk_every(requests, max_lines)}
  end

  def partition_requests_for_check(_requests, _shell_ceiling),
    do: {:error, "git_invalid_object_request"}

  @doc false
  @spec batch_object_wire_bytes(object_spec()) :: non_neg_integer()
  def batch_object_wire_bytes(%{oid: oid, type: type, size: size})
      when is_binary(oid) and is_binary(type) and is_integer(size) and size >= 0 do
    byte_size(oid) + 1 + byte_size(type) + 1 + byte_size(Integer.to_string(size)) + 1 + size + 1
  end

  def batch_object_wire_bytes(_spec), do: 0

  defp normalize_object_request(%{oid: oid, type: type})
       when is_binary(oid) and is_binary(type) do
    cond do
      not Regex.match?(@oid_pattern, oid) ->
        {:error, "git_invalid_object_oid"}

      not MapSet.member?(@allowed_object_types, type) ->
        {:error, "git_invalid_object_type"}

      true ->
        {:ok, %{oid: oid, type: type}}
    end
  end

  defp normalize_object_request(%{"oid" => oid, "type" => type})
       when is_binary(oid) and is_binary(type) do
    normalize_object_request(%{oid: oid, type: type})
  end

  defp normalize_object_request(_request), do: {:error, "git_invalid_object_request"}

  defp batch_check_objects(workdir, requests, timeout, max_object_bytes, max_total_bytes) do
    shell_ceiling = shell_output_ceiling()

    with {:ok, check_batches} <- partition_requests_for_check(requests, shell_ceiling),
         {:ok, specs, process_count} <-
           Enum.reduce_while(check_batches, {:ok, [], 0}, fn batch, {:ok, acc, count} ->
             case run_batch_check(workdir, batch, timeout, shell_ceiling) do
               {:ok, batch_specs} -> {:cont, {:ok, acc ++ batch_specs, count + 1}}
               {:error, _reason} = error -> {:halt, error}
             end
           end),
         :ok <- validate_object_budget(specs, max_object_bytes, max_total_bytes) do
      {:ok, specs, process_count}
    end
  end

  defp run_batch_check(workdir, requests, timeout, shell_ceiling) do
    stdin = oid_stdin(Enum.map(requests, & &1.oid))
    max_output_bytes = min(shell_ceiling, length(requests) * @batch_check_line_overhead + 64)

    with {:ok, output} <-
           run_with_stdin(
             workdir,
             ["cat-file", "--batch-check"],
             timeout,
             stdin,
             max_output_bytes
           ),
         {:ok, specs} <- parse_batch_check_output(output, requests) do
      {:ok, specs}
    end
  end

  defp validate_object_budget(specs, max_object_bytes, max_total_bytes) do
    total =
      Enum.reduce_while(specs, 0, fn %{size: size}, acc ->
        if size <= max_object_bytes and acc + size <= max_total_bytes do
          {:cont, acc + size}
        else
          {:halt, :overflow}
        end
      end)

    if total == :overflow do
      {:error, "fixture_object_attestation_failed"}
    else
      :ok
    end
  end

  defp fetch_object_batches(workdir, batches, timeout, shell_ceiling) do
    Enum.reduce_while(batches, {:ok, %{}, 0}, fn batch, {:ok, acc, process_count} ->
      case fetch_object_batch(workdir, batch, timeout, shell_ceiling) do
        {:ok, objects} ->
          conflict? =
            Enum.any?(objects, fn {oid, payload} ->
              case Map.fetch(acc, oid) do
                :error -> false
                {:ok, existing} -> existing != payload
              end
            end)

          if conflict? do
            {:halt, {:error, "git_object_duplicate_conflict"}}
          else
            {:cont, {:ok, Map.merge(acc, objects), process_count + 1}}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp fetch_object_batch(workdir, {:batch, specs}, timeout, shell_ceiling) do
    stdin = oid_stdin(Enum.map(specs, & &1.oid))

    max_output_bytes =
      Enum.reduce(specs, 0, fn spec, acc -> acc + batch_object_wire_bytes(spec) end)

    with true <- max_output_bytes > 0 and max_output_bytes <= shell_ceiling,
         {:ok, output} <-
           run_with_stdin(
             workdir,
             ["cat-file", "--batch"],
             timeout,
             stdin,
             max_output_bytes
           ),
         {:ok, objects} <- parse_batch_objects_output(output, specs) do
      {:ok, objects}
    else
      false -> {:error, "git_batch_budget_exceeded"}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_object_batch(
         workdir,
         {:single, %{oid: oid, type: type, size: size}},
         timeout,
         shell_ceiling
       ) do
    max_output_bytes = min(size, shell_ceiling)

    # Single-object form returns raw content only (no batch framing).
    with true <- size <= shell_ceiling,
         {:ok, content} <-
           run(workdir, ["cat-file", type, oid], timeout,
             max_output_bytes: max(max_output_bytes, 1)
           ),
         true <- byte_size(content) == size do
      {:ok,
       %{
         oid => %{
           type: type,
           size: size,
           content: :binary.copy(content)
         }
       }}
    else
      false -> {:error, "git_object_size_mismatch"}
      {:error, _reason} = error -> error
    end
  end

  defp parse_batch_check_line(line, %{oid: expected_oid, type: expected_type}) do
    case :binary.split(line, " ", [:global]) do
      [oid, "missing"] ->
        cond do
          not Regex.match?(@oid_pattern, oid) ->
            {:error, "git_batch_check_malformed"}

          oid == expected_oid ->
            {:error, "git_object_missing"}

          true ->
            {:error, "git_batch_check_oid_mismatch"}
        end

      [oid, type, size_text] ->
        cond do
          not Regex.match?(@oid_pattern, oid) or not MapSet.member?(@allowed_object_types, type) ->
            {:error, "git_batch_check_malformed"}

          oid != expected_oid ->
            {:error, "git_batch_check_oid_mismatch"}

          type != expected_type ->
            {:error, "git_batch_check_type_mismatch"}

          true ->
            case Integer.parse(size_text) do
              {size, ""} when size >= 0 ->
                {:ok, %{oid: oid, type: type, size: size}}

              _other ->
                {:error, "git_batch_check_malformed"}
            end
        end

      _other ->
        {:error, "git_batch_check_malformed"}
    end
  end

  defp parse_batch_objects_output(<<>>, [], acc), do: {:ok, acc}

  defp parse_batch_objects_output(_output, [], _acc), do: {:error, "git_batch_trailing_bytes"}

  defp parse_batch_objects_output(output, [spec | rest], acc) do
    case parse_one_batch_object(output, spec) do
      {:ok, payload, remainder} ->
        parse_batch_objects_output(remainder, rest, Map.put(acc, spec.oid, payload))

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_one_batch_object(output, %{
         oid: expected_oid,
         type: expected_type,
         size: expected_size
       }) do
    case split_header_line(output) do
      {:ok, header, after_header} ->
        case :binary.split(header, " ", [:global]) do
          [oid, "missing"] ->
            cond do
              not Regex.match?(@oid_pattern, oid) ->
                {:error, "git_batch_header_malformed"}

              oid == expected_oid ->
                {:error, "git_object_missing"}

              true ->
                {:error, "git_batch_oid_mismatch"}
            end

          [oid, type, size_text] ->
            cond do
              not Regex.match?(@oid_pattern, oid) or
                  not MapSet.member?(@allowed_object_types, type) ->
                {:error, "git_batch_header_malformed"}

              oid != expected_oid ->
                {:error, "git_batch_oid_mismatch"}

              type != expected_type ->
                {:error, "git_batch_type_mismatch"}

              true ->
                case Integer.parse(size_text) do
                  {size, ""} when size == expected_size and byte_size(after_header) >= size + 1 ->
                    case after_header do
                      <<content::binary-size(size), ?\n, remainder::binary>> ->
                        {:ok,
                         %{
                           type: type,
                           size: size,
                           content: :binary.copy(content)
                         }, remainder}

                      _other ->
                        {:error, "git_batch_payload_truncated"}
                    end

                  {size, ""} when size != expected_size ->
                    {:error, "git_batch_size_or_order_mismatch"}

                  _other ->
                    {:error, "git_batch_header_malformed"}
                end
            end

          _other ->
            {:error, "git_batch_header_malformed"}
        end

      :error ->
        {:error, "git_batch_header_malformed"}
    end
  end

  defp split_header_line(output) do
    case :binary.split(output, "\n", []) do
      [header, rest] -> {:ok, header, rest}
      _other -> :error
    end
  end

  defp split_exact_lines(<<>>), do: {:ok, []}

  defp split_exact_lines(output) when is_binary(output) do
    case :binary.split(output, "\n", [:global]) do
      parts ->
        case List.last(parts) do
          "" ->
            lines = Enum.drop(parts, -1)

            if Enum.any?(lines, &(&1 == "")) do
              {:error, "git_batch_check_malformed"}
            else
              {:ok, lines}
            end

          _trailing_without_newline ->
            {:error, "git_batch_check_missing_final_newline"}
        end
    end
  end

  defp flush_batch(batches, nil), do: batches
  defp flush_batch(batches, {group, _used, _count}), do: [{:batch, Enum.reverse(group)} | batches]

  defp valid_object_spec?(%{oid: oid, type: type, size: size})
       when is_binary(oid) and is_binary(type) and is_integer(size) and size >= 0 do
    Regex.match?(@oid_pattern, oid) and MapSet.member?(@allowed_object_types, type)
  end

  defp valid_object_spec?(_spec), do: false

  defp validate_object_request_count([]), do: {:error, "git_empty_object_request"}

  defp validate_object_request_count(requests) when is_list(requests) do
    # length/1 is O(n); bound early so empty zero-byte objects cannot skip cardinality.
    case bounded_list_length(requests, @max_object_requests) do
      {:ok, _count} -> :ok
      :overflow -> {:error, "git_object_request_limit"}
    end
  end

  defp validate_object_request_count(_requests), do: {:error, "git_invalid_object_request"}

  defp bounded_list_length(list, max) when is_list(list) and is_integer(max) and max >= 0 do
    bounded_list_length(list, max, 0)
  end

  defp bounded_list_length([], _max, count), do: {:ok, count}

  defp bounded_list_length(_list, max, count) when count >= max, do: :overflow

  defp bounded_list_length([_head | tail], max, count),
    do: bounded_list_length(tail, max, count + 1)

  defp oid_stdin(oids) when is_list(oids) do
    Enum.map_join(oids, "", fn oid -> oid <> "\n" end)
  end

  defp shell_output_ceiling do
    case function_exported?(Arbor.Shell, :max_output_bytes_limit, 0) do
      true -> min(Arbor.Shell.max_output_bytes_limit(), @shell_output_ceiling)
      false -> @shell_output_ceiling
    end
  end

  defp emit_object_batch_telemetry(object_count, batch_count, process_count) do
    :telemetry.execute(
      [:arbor, :commands, :coding_benchmark, :git_object_batch],
      %{
        object_count: object_count,
        batch_count: batch_count,
        process_count: process_count
      },
      %{}
    )
  end

  defp remaining_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: {:ok, timeout_ms}

  defp remaining_timeout({:deadline, deadline}) when is_integer(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _expired -> {:error, "git_timeout:deadline_exceeded"}
    end
  end

  defp remaining_timeout(_timeout), do: {:error, "git_invalid_request"}

  defp run_with_stdin(workdir, args, timeout, stdin, max_output_bytes)
       when is_binary(workdir) and is_list(args) and is_binary(stdin) do
    with {:ok, timeout_ms} <- remaining_timeout(timeout),
         true <-
           is_integer(max_output_bytes) and max_output_bytes > 0 and
             max_output_bytes <= @max_configured_output_bytes do
      execute(
        ["--no-replace-objects", "-C", workdir] ++ @neutral_config ++ args,
        timeout_ms,
        max_output_bytes,
        stdin
      )
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, "git_invalid_request"}
    end
  end

  defp execute(args, timeout_ms, max_output_bytes, stdin) do
    opts =
      [
        sandbox: :none,
        timeout: timeout_ms,
        max_output_bytes: max_output_bytes,
        clear_env: true,
        env: @neutral_env
      ]
      |> maybe_put_stdin(stdin)

    case Arbor.Shell.execute_direct("git", args, opts) do
      {:ok, %{timed_out: true}} ->
        {:error, "git_timeout:#{timeout_ms}"}

      {:ok, %{output_limit_exceeded: true, stdout: output}} ->
        {:error, "git_output_limit:#{bounded_output(output)}"}

      {:ok, %{exit_code: 0, stdout: output}} ->
        {:ok, output}

      {:ok, %{exit_code: status, stdout: output}} ->
        {:error, "git_failed:#{status}:#{bounded_output(output)}"}

      {:error, reason} ->
        {:error, "git_execution_failed:#{bounded_output(inspect(reason))}"}
    end
  catch
    :exit, reason -> {:error, "git_shell_unavailable:#{bounded_output(inspect(reason))}"}
  end

  defp maybe_put_stdin(opts, nil), do: opts
  defp maybe_put_stdin(opts, stdin) when is_binary(stdin), do: Keyword.put(opts, :stdin, stdin)

  # Total over arbitrary binaries (including invalid UTF-8 batch payloads).
  # Never raise and never turn untrusted bytes into atoms.
  defp bounded_output(output) when is_binary(output) do
    take = min(byte_size(output), @max_diagnostic_bytes)
    head = binary_part(output, 0, take)
    sanitize_diagnostic_bytes(head)
  end

  defp bounded_output(output) do
    output
    |> inspect(limit: 20, printable_limit: @max_diagnostic_bytes, safe: true)
    |> then(fn text when is_binary(text) ->
      binary_part(text, 0, min(byte_size(text), @max_diagnostic_bytes))
    end)
  end

  defp sanitize_diagnostic_bytes(bin) when is_binary(bin) do
    sanitized =
      for <<byte <- bin>>, into: <<>> do
        cond do
          byte in ?\s..?~ -> <<byte>>
          byte in [?\t, ?\n, ?\r] -> <<" ">>
          true -> <<"?">>
        end
      end

    trim_ascii_spaces(sanitized)
  end

  defp trim_ascii_spaces(bin) when is_binary(bin) do
    bin
    |> trim_leading_ascii_spaces()
    |> trim_trailing_ascii_spaces()
  end

  defp trim_leading_ascii_spaces(<<" ", rest::binary>>), do: trim_leading_ascii_spaces(rest)
  defp trim_leading_ascii_spaces(bin), do: bin

  defp trim_trailing_ascii_spaces(<<>>), do: <<>>

  defp trim_trailing_ascii_spaces(bin) do
    size = byte_size(bin)

    case binary_part(bin, size - 1, 1) do
      <<" ">> -> trim_trailing_ascii_spaces(binary_part(bin, 0, size - 1))
      _other -> bin
    end
  end
end

defmodule Arbor.Commands.CodingBenchmark.Git do
  @moduledoc false

  @max_output_bytes 65_536
  @max_configured_output_bytes 268_435_456
  @shell_output_ceiling 16_777_216
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
  members). Each unique OID is returned once with independently owned content
  bytes.
  """
  @spec read_objects(String.t(), [object_request()], timeout_spec(), keyword()) ::
          {:ok, %{optional(String.t()) => object_payload()}} | {:error, String.t()}
  def read_objects(workdir, requests, timeout, opts \\ [])

  def read_objects(workdir, requests, timeout, opts)
      when is_binary(workdir) and is_list(requests) and is_list(opts) do
    max_object_bytes = Keyword.get(opts, :max_object_bytes, @shell_output_ceiling)
    max_total_bytes = Keyword.get(opts, :max_total_bytes, @max_configured_output_bytes)
    shell_ceiling = shell_output_ceiling()

    with {:ok, normalized} <- normalize_object_requests(requests),
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
  @spec normalize_object_requests(term()) ::
          {:ok, [object_request()]} | {:error, String.t()}
  def normalize_object_requests(requests) when is_list(requests) do
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
      {:ok, acc, _seen} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  def normalize_object_requests(_requests), do: {:error, "git_invalid_object_request"}

  @doc false
  @spec parse_batch_check_output(binary(), [object_request()]) ::
          {:ok, [object_spec()]} | {:error, String.t()}
  def parse_batch_check_output(output, requests)
      when is_binary(output) and is_list(requests) do
    lines = split_exact_lines(output)

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

  def parse_batch_check_output(_output, _requests), do: {:error, "git_batch_check_malformed"}

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
              {:cont, {:ok, batches, {[spec], cost}}}

            {group, used} when used + cost <= max_output_bytes ->
              {:cont, {:ok, batches, {[spec | group], used + cost}}}

            {group, _used} ->
              {:cont, {:ok, [{:batch, Enum.reverse(group)} | batches], {[spec], cost}}}
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

  defp partition_requests_for_check(requests, shell_ceiling) do
    max_lines = max(div(shell_ceiling, @batch_check_line_overhead), 1)

    {:ok, Enum.chunk_every(requests, max_lines)}
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

  defp split_exact_lines(output) do
    case output do
      <<>> ->
        []

      _other ->
        case :binary.split(output, "\n", [:global]) do
          parts ->
            case List.last(parts) do
              "" -> Enum.drop(parts, -1)
              _trailing_without_newline -> parts
            end
        end
    end
  end

  defp flush_batch(batches, nil), do: batches
  defp flush_batch(batches, {group, _used}), do: [{:batch, Enum.reverse(group)} | batches]

  defp valid_object_spec?(%{oid: oid, type: type, size: size})
       when is_binary(oid) and is_binary(type) and is_integer(size) and size >= 0 do
    Regex.match?(@oid_pattern, oid) and MapSet.member?(@allowed_object_types, type)
  end

  defp valid_object_spec?(_spec), do: false

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

  defp bounded_output(output) when is_binary(output) do
    output
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp bounded_output(output),
    do: output |> inspect(limit: 20, printable_limit: 500) |> String.slice(0, 500)
end

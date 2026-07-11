defmodule Arbor.AI.Eval.RetrievalSupport do
  @moduledoc false

  @max_index_bytes 16_777_216
  @max_index_entries 2_000
  @max_prompt_bytes 1_048_576
  @max_module_bytes 512
  @max_description_bytes 16_384
  @max_index_model_bytes 512
  @max_router_response_bytes 262_144
  @max_router_prompt_bytes 1_048_576
  @max_http_diagnostic_bytes 2_048
  @max_external_diagnostic_bytes 512
  @max_external_items 16
  @max_external_depth 4
  @max_vector_dimensions 8_192
  # Keeps dot/norm accumulation finite at the maximum vector dimension.
  @max_vector_component_abs 1.0e100
  @max_embedding_models 100
  @max_protocol_integer 9_223_372_036_854_775_807
  @min_protocol_integer -9_223_372_036_854_775_808
  @decoded_term_limits [
    max_bytes: 16_777_216,
    max_nodes: 100_000,
    max_depth: 32,
    max_map_keys: 10_000,
    max_list_items: 100_000
  ]
  @index_read_deadline_ms 500
  @index_reader_heap_words 8_388_608
  @http_cleanup_wait_ms 250
  @darwin_open_helper "/usr/bin/perl"
  @darwin_open_script ~S"""
  use strict;
  use Fcntl qw(O_RDONLY O_NONBLOCK O_NOFOLLOW S_ISREG);
  my ($path, $max, $ino, $size, $mtime, $ctime) = @ARGV;
  sub fail_with { print "E\t$_[0]\n"; exit 0; }
  sysopen(my $fh, $path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) or fail_with("OPEN");
  my @before = stat($fh);
  @before or fail_with("FSTAT");
  S_ISREG($before[2]) or fail_with("NOT_REGULAR");
  ($before[1] == $ino && $before[7] == $size && $before[9] == $mtime && $before[10] == $ctime)
    or fail_with("CHANGED");
  binmode($fh);
  my $body = "";
  while (1) {
    my $remaining = $max + 1 - length($body);
    my $read = sysread($fh, my $chunk, $remaining);
    defined($read) or fail_with("READ");
    last if $read == 0;
    $body .= $chunk;
    fail_with("TOO_LARGE") if length($body) > $max;
  }
  my @after = stat($fh);
  my @path = lstat($path);
  (@after && @path && S_ISREG($after[2]) && S_ISREG($path[2])) or fail_with("CHANGED");
  ($after[1] == $ino && $after[7] == $size && $after[9] == $mtime && $after[10] == $ctime)
    or fail_with("CHANGED");
  ($path[1] == $ino && $path[7] == $size && $path[9] == $mtime && $path[10] == $ctime)
    or fail_with("CHANGED");
  print "O\n", $body;
  """

  @string_byte_limits %{
    index_path: 4_096,
    model: 512,
    embed_model: 512,
    base_url: 4_096,
    embed_url: 4_096,
    judge_model: 512,
    judge_provider: 256
  }

  @positive_integer_limits %{
    top_k: 100,
    candidate_k: 500,
    max_desc_chars: 4_096,
    timeout: 300_000,
    judge_timeout: 300_000
  }

  @type action :: %{
          module: String.t(),
          description: String.t(),
          embeddings: %{optional(String.t()) => [number()]}
        }

  @spec validate_opts(term()) :: :ok | {:error, term()}
  def validate_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, {:invalid_options, :keyword_required}}
  end

  def validate_opts(_opts), do: {:error, {:invalid_options, :keyword_required}}

  @spec extract_prompt(term()) :: {:ok, String.t()} | {:error, term()}
  def extract_prompt(%{"prompt" => prompt}) when is_binary(prompt) and prompt != "",
    do: validate_prompt(prompt)

  def extract_prompt(prompt) when is_binary(prompt) and prompt != "",
    do: validate_prompt(prompt)

  def extract_prompt(_input), do: {:error, {:invalid_input, :prompt_required}}

  @spec required_string(keyword(), atom()) :: {:ok, String.t()} | {:error, term()}
  def required_string(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        validate_option_string(value, key)

      {:ok, _value} ->
        {:error, {:invalid_option, key, :non_empty_string_required}}

      :error ->
        {:error, {:missing_option, key}}
    end
  end

  @spec string_option(keyword(), atom(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def string_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_binary(value) and value != "" ->
        validate_option_string(value, key)

      _value ->
        {:error, {:invalid_option, key, :non_empty_string_required}}
    end
  end

  @spec endpoint_option(keyword(), atom(), String.t(), :base | :embedding) ::
          {:ok, String.t()} | {:error, term()}
  def endpoint_option(opts, key, default, policy) do
    with {:ok, value} <- string_option(opts, key, default),
         endpoint_policy = if(policy == :base, do: :root, else: :embedding),
         {:ok, canonical} <- Arbor.LLM.validate_endpoint(value, endpoint_policy) do
      {:ok, canonical}
    else
      {:error, {:invalid_option, ^key, _reason} = error} -> {:error, error}
      {:error, reason} -> {:error, {:invalid_option, key, reason}}
    end
  end

  @spec positive_integer_option(keyword(), atom(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  def positive_integer_option(opts, key, default) do
    value = Keyword.get(opts, key, default)

    case Map.fetch(@positive_integer_limits, key) do
      {:ok, maximum} when is_integer(value) and value > 0 and value <= maximum ->
        {:ok, value}

      {:ok, maximum} ->
        {:error, {:invalid_option, key, {:integer_range_required, 1, maximum}}}

      :error when is_integer(value) and value > 0 ->
        {:ok, value}

      :error ->
        {:error, {:invalid_option, key, :positive_integer_required}}
    end
  end

  @spec optional_positive_integer_option(keyword(), atom()) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def optional_positive_integer_option(opts, key) do
    case Keyword.fetch(opts, key) do
      :error ->
        {:ok, nil}

      {:ok, value}
      when is_integer(value) and value > 0 and value <= @max_protocol_integer ->
        {:ok, value}

      {:ok, value} when is_integer(value) and value > @max_protocol_integer ->
        {:error, {:invalid_option, key, {:integer_range_required, 1, @max_protocol_integer}}}

      {:ok, _value} ->
        {:error, {:invalid_option, key, :positive_integer_required}}
    end
  end

  @spec callback_option(keyword(), atom(), arity(), function()) ::
          {:ok, function()} | {:error, term()}
  def callback_option(opts, key, arity, default) do
    case Keyword.get(opts, key, default) do
      callback when is_function(callback, arity) -> {:ok, callback}
      _callback -> {:error, {:invalid_option, key, {:function_required, arity}}}
    end
  end

  @spec invoke(function(), [term()], atom()) :: term()
  def invoke(callback, args, error_tag) do
    case apply(callback, args) do
      {:error, reason} -> {:error, bounded_external_reason(reason)}
      result -> result
    end
  rescue
    exception -> {:error, {error_tag, exception_diagnostic(exception)}}
  catch
    :exit, reason -> {:error, {error_tag, {:exit, bounded_external_reason(reason)}}}
    kind, reason -> {:error, {error_tag, {kind, bounded_external_reason(reason)}}}
  end

  @doc false
  @spec bounded_external_reason(term()) :: term()
  def bounded_external_reason(
        {tag, status, %{body_excerpt: excerpt, truncated: truncated?}} = reason
      )
      when is_atom(tag) and is_integer(status) and is_binary(excerpt) and
             byte_size(excerpt) <= @max_http_diagnostic_bytes and is_boolean(truncated?),
      do: reason

  def bounded_external_reason(value), do: bound_term(value, @max_external_depth)

  @doc false
  @spec post_json(String.t(), term(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer(), term()} | {:error, term()}
  def post_json(url, json, timeout, max_response_bytes)
      when is_binary(url) and is_integer(timeout) and timeout > 0 and
             is_integer(max_response_bytes) and max_response_bytes > 0 do
    deadline_ms = System.monotonic_time(:millisecond) + timeout

    run_owned_http_deadline(
      fn -> do_post_json(url, json, deadline_ms, max_response_bytes) end,
      deadline_ms,
      timeout
    )
  end

  defp do_post_json(url, json, deadline_ms, max_response_bytes) do
    into = bounded_response_collector(max_response_bytes)

    case Req.post(url,
           json: json,
           receive_timeout: max(deadline_ms - System.monotonic_time(:millisecond), 1),
           redirect: false,
           compressed: false,
           decode_body: false,
           into: into
         ) do
      {:ok, %Req.Response{private: %{arbor_eval_response_overflow: true}}} ->
        {:error, {:http_response_bytes_exceeded, max_response_bytes}}

      {:ok, %Req.Response{status: status} = response} ->
        with :ok <- identity_content_encoding(response),
             {:ok, body} <- collected_response_body(response) do
          if status in 200..299 do
            with :ok <- success_json_content_type(response, body),
                 {:ok, decoded} <- decode_bounded_json_body(body, max_response_bytes) do
              {:ok, status, decoded}
            end
          else
            with {:ok, bounded_body} <- decode_error_body(response, body, max_response_bytes) do
              {:ok, status, bounded_body}
            end
          end
        end

      {:error, reason} ->
        {:error, {:transport_error, bounded_external_reason(reason)}}
    end
  rescue
    exception -> {:error, {:transport_error, exception_diagnostic(exception)}}
  catch
    kind, reason -> {:error, {:transport_error, {kind, bounded_external_reason(reason)}}}
  end

  defp run_owned_http_deadline(fun, deadline_ms, timeout) do
    reply_alias = :erlang.alias()

    {pid, monitor_ref} =
      spawn_monitor(fn -> send(reply_alias, {reply_alias, fun.()}) end)

    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^reply_alias, result} ->
        :erlang.unalias(reply_alias)
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        :erlang.unalias(reply_alias)
        {:error, {:transport_error, {:producer_exit, bounded_external_reason(reason)}}}
    after
      remaining_ms ->
        :erlang.unalias(reply_alias)
        Process.exit(pid, :kill)
        await_http_down(pid, monitor_ref)
        {:error, {:transport_error, {:deadline_exceeded, timeout}}}
    end
  end

  defp await_http_down(pid, monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      @http_cleanup_wait_ms -> Process.demonitor(monitor_ref, [:flush])
    end
  end

  @spec truncate_utf8(String.t(), pos_integer()) :: String.t()
  def truncate_utf8(text, max_bytes)
      when is_binary(text) and is_integer(max_bytes) and max_bytes > 0 do
    if byte_size(text) <= max_bytes do
      text
    else
      suffix_size = min(byte_size("..."), max_bytes)
      prefix_budget = max_bytes - suffix_size
      bounded_utf8_prefix(text, prefix_budget) <> binary_part("...", 0, suffix_size)
    end
  end

  @spec load_index(String.t()) :: {:ok, [action()]} | {:error, term()}
  def load_index(path) when is_binary(path) and path != "" do
    with {:ok, path} <- validate_option_string(path, :index_path),
         {:ok, body} <- read_index(path),
         {:ok, decoded} <- decode_index(path, body),
         {:ok, actions} <- normalize_index(path, decoded) do
      {:ok, actions}
    end
  end

  def load_index(_path),
    do: {:error, {:invalid_option, :index_path, :non_empty_string_required}}

  @spec embeddings_for_model([action()], String.t(), String.t()) ::
          {:ok, [{String.t(), [number()]}]} | {:error, term()}
  def embeddings_for_model(actions, model, index_path) do
    indexed =
      Enum.flat_map(actions, fn action ->
        case Map.get(action.embeddings, model) do
          vector when is_list(vector) -> [{action.module, vector}]
          nil -> []
        end
      end)

    case indexed do
      [] -> {:error, {:model_not_indexed, model, index_path}}
      _ -> {:ok, indexed}
    end
  end

  @spec validate_vector(term()) :: {:ok, [number()]} | {:error, term()}
  def validate_vector(vector) do
    case validate_vector_values(vector) do
      {:ok, _dimensions} -> {:ok, vector}
      {:error, reason} -> {:error, {:invalid_embedding_response, reason}}
    end
  end

  @spec validate_query_dimensions([{String.t(), [number()]}], [number()]) ::
          :ok | {:error, term()}
  def validate_query_dimensions([{_module, indexed_vector} | _], query_vector) do
    indexed_dimensions = length(indexed_vector)
    query_dimensions = length(query_vector)

    if indexed_dimensions == query_dimensions do
      :ok
    else
      {:error,
       {:invalid_embedding_response,
        {:vector_dimension_mismatch, indexed_dimensions, query_dimensions}}}
    end
  end

  def validate_query_dimensions([], _query_vector), do: :ok

  @spec parse_router_response(String.t(), MapSet.t(String.t()), pos_integer()) ::
          {:ok, [String.t()]} | {:error, term()}
  def parse_router_response(content, known_modules, top_k)
      when is_binary(content) and is_struct(known_modules, MapSet) do
    cond do
      byte_size(content) > @max_router_response_bytes ->
        {:error, {:invalid_router_response, {:content_size_exceeded, @max_router_response_bytes}}}

      not String.valid?(content) ->
        {:error, {:invalid_router_response, :valid_utf8_required}}

      true ->
        decode_router_response(content, known_modules, top_k)
    end
  end

  @doc false
  @spec http_error(atom(), term(), term()) :: {:error, term()}
  def http_error(tag, status, body) when is_atom(tag) do
    {:error, {tag, bounded_external_reason(status), diagnostic_excerpt(body)}}
  end

  @doc false
  @spec validate_router_prompt(String.t()) :: {:ok, String.t()} | {:error, term()}
  def validate_router_prompt(prompt) when is_binary(prompt) do
    cond do
      byte_size(prompt) > @max_router_prompt_bytes ->
        {:error, {:router_prompt_size_exceeded, @max_router_prompt_bytes}}

      String.valid?(prompt) ->
        {:ok, prompt}

      true ->
        {:error, :router_prompt_valid_utf8_required}
    end
  end

  @spec rank([{String.t(), [number()]}], [number()], pos_integer()) :: [map()]
  def rank(indexed_actions, query_vector, top_k) do
    indexed_actions
    |> Enum.map(fn {module, action_vector} ->
      %{module: module, score: cosine_similarity(query_vector, action_vector)}
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(top_k)
  end

  @spec cosine_similarity([number()], [number()]) :: float()
  def cosine_similarity(a, b) when is_list(a) and is_list(b) do
    with {:ok, a} <- validate_vector(a),
         {:ok, b} <- validate_vector(b),
         true <- length(a) == length(b),
         a_scale when a_scale > 0.0 <- vector_scale(a),
         b_scale when b_scale > 0.0 <- vector_scale(b) do
      scaled_cosine(a, b, a_scale, b_scale)
    else
      _invalid_or_zero -> 0.0
    end
  end

  def cosine_similarity(_a, _b), do: 0.0

  defp vector_scale(vector) do
    Enum.reduce(vector, 0.0, fn value, scale -> max(scale, abs(value * 1.0)) end)
  end

  defp scaled_cosine(a, b, a_scale, b_scale) do
    {dot, a_norm_squared, b_norm_squared} =
      a
      |> Enum.zip(b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {dot, a_norm, b_norm} ->
        scaled_x = x / a_scale
        scaled_y = y / b_scale

        {
          dot + scaled_x * scaled_y,
          a_norm + scaled_x * scaled_x,
          b_norm + scaled_y * scaled_y
        }
      end)

    denominator = :math.sqrt(a_norm_squared) * :math.sqrt(b_norm_squared)

    if finite_intermediates?([dot, a_norm_squared, b_norm_squared, denominator]) and
         denominator > 0.0 do
      similarity = dot / denominator

      if Arbor.LLM.finite_number?(similarity),
        do: min(1.0, max(-1.0, similarity)),
        else: 0.0
    else
      0.0
    end
  end

  defp finite_intermediates?(values), do: Enum.all?(values, &Arbor.LLM.finite_number?/1)

  defp validate_prompt(prompt) do
    validate_bounded_utf8(
      prompt,
      @max_prompt_bytes,
      {:invalid_input, {:prompt_bytes_exceeded, @max_prompt_bytes}},
      {:invalid_input, :valid_utf8_prompt_required}
    )
  end

  defp validate_option_string(value, key) do
    maximum = Map.get(@string_byte_limits, key, 4_096)

    validate_bounded_utf8(
      value,
      maximum,
      {:invalid_option, key, {:byte_size_exceeded, maximum}},
      {:invalid_option, key, :valid_utf8_required}
    )
  end

  defp validate_index_string(value, field, maximum) do
    validate_bounded_utf8(
      value,
      maximum,
      {:field_bytes_exceeded, field, maximum},
      {:field_valid_utf8_required, field}
    )
  end

  defp validate_bounded_utf8(value, maximum, size_error, utf8_error) do
    cond do
      byte_size(value) > maximum -> {:error, size_error}
      String.valid?(value) -> {:ok, value}
      true -> {:error, utf8_error}
    end
  end

  defp decode_router_response(content, known_modules, top_k) do
    case Arbor.LLM.decode_bounded_json(content, router_term_limits()) do
      {:ok, %{"selected" => list}} when is_list(list) ->
        normalize_router_modules(list, known_modules, top_k)

      {:ok, %{"actions" => list}} when is_list(list) ->
        normalize_router_modules(list, known_modules, top_k)

      {:ok, list} when is_list(list) ->
        normalize_router_modules(list, known_modules, top_k)

      {:ok, _other} ->
        {:error, {:invalid_router_response, :selected_list_required}}

      {:error, _decode_error} ->
        {:error, {:invalid_router_response, :malformed_json}}
    end
  end

  defp normalize_router_modules(list, known_modules, top_k) do
    normalized =
      list
      |> Enum.filter(&is_binary/1)
      |> Enum.filter(&(byte_size(&1) <= @max_module_bytes))
      |> Enum.filter(&MapSet.member?(known_modules, &1))
      |> Enum.uniq()
      |> Enum.take(top_k)

    if list != [] and normalized == [] do
      {:error, {:invalid_router_response, :known_module_required}}
    else
      {:ok, normalized}
    end
  end

  defp read_index(path) do
    with {:ok, expected_identity} <- index_path_identity(path),
         :ok <- validate_index_size(path, expected_identity.size) do
      open_and_read_index(path, expected_identity)
    end
  rescue
    exception -> {:error, {:index_read_failed, path, Exception.message(exception)}}
  end

  defp index_path_identity(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        {:ok, file_identity(stat)}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:index_file_rejected, path, :symlink}}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:index_file_rejected, path, {:not_regular, type}}}

      {:error, reason} ->
        {:error, {:index_read_failed, path, reason}}
    end
  end

  defp descriptor_identity(io) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, file_info} ->
        case File.Stat.from_record(file_info) do
          %File.Stat{type: :regular} = stat ->
            {:ok, file_identity(stat)}

          %File.Stat{type: type} ->
            {:error, {:opened_not_regular, type}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp file_identity(stat) do
    %{
      inode: stat.inode,
      major_device: stat.major_device,
      minor_device: stat.minor_device,
      size: stat.size,
      mtime: stat.mtime,
      ctime: stat.ctime
    }
  end

  defp validate_index_size(path, size) when is_integer(size) and size > @max_index_bytes,
    do: {:error, {:index_size_exceeded, path, @max_index_bytes}}

  defp validate_index_size(_path, size) when is_integer(size) and size >= 0, do: :ok
  defp validate_index_size(path, _size), do: {:error, {:index_read_failed, path, :invalid_size}}

  defp open_and_read_index(path, expected_identity) do
    if :os.type() == {:unix, :darwin} and File.regular?(@darwin_open_helper) do
      open_and_read_index_darwin(path, expected_identity)
    else
      open_and_read_index_worker_deadline(path, expected_identity)
    end
  end

  defp open_and_read_index_darwin(path, expected_identity) do
    # O_NOFOLLOW protects the final component and O_NONBLOCK prevents a FIFO
    # swap from pinning a scheduler. Identity checks detect regular-file swaps.
    # Parent-directory replacement remains a trusted-directory residual.
    args = [
      "-e",
      @darwin_open_script,
      "--",
      path,
      Integer.to_string(@max_index_bytes),
      Integer.to_string(expected_identity.inode),
      Integer.to_string(expected_identity.size),
      Integer.to_string(expected_identity.mtime),
      Integer.to_string(expected_identity.ctime)
    ]

    port =
      Port.open(
        {:spawn_executable, @darwin_open_helper},
        [:binary, :use_stdio, :stderr_to_stdout, :exit_status, args: args]
      )

    collect_open_helper(port, path, System.monotonic_time(:millisecond), [], 0)
  rescue
    exception -> {:error, {:index_read_failed, path, exception_diagnostic(exception)}}
  end

  defp collect_open_helper(port, path, started_at, chunks, retained_bytes) do
    remaining_ms = @index_read_deadline_ms - (System.monotonic_time(:millisecond) - started_at)

    if remaining_ms <= 0 do
      close_open_helper(port)
      {:error, {:index_read_failed, path, :read_deadline_exceeded}}
    else
      receive do
        {^port, {:data, data}} when is_binary(data) ->
          retained_bytes = retained_bytes + byte_size(data)

          if retained_bytes > @max_index_bytes + 4_096 do
            close_open_helper(port)
            {:error, {:index_size_exceeded, path, @max_index_bytes}}
          else
            collect_open_helper(port, path, started_at, [data | chunks], retained_bytes)
          end

        {^port, {:exit_status, 0}} ->
          chunks
          |> Enum.reverse()
          |> IO.iodata_to_binary()
          |> parse_open_helper_result(path)

        {^port, {:exit_status, _status}} ->
          {:error, {:index_read_failed, path, :open_helper_failed}}
      after
        remaining_ms ->
          close_open_helper(port)
          {:error, {:index_read_failed, path, :read_deadline_exceeded}}
      end
    end
  end

  defp parse_open_helper_result("O\n" <> body, _path), do: {:ok, body}

  defp parse_open_helper_result("E\tTOO_LARGE\n", path),
    do: {:error, {:index_size_exceeded, path, @max_index_bytes}}

  defp parse_open_helper_result("E\tNOT_REGULAR\n", path),
    do: {:error, {:index_file_rejected, path, {:not_regular, :other}}}

  defp parse_open_helper_result("E\tCHANGED\n", path),
    do: {:error, {:index_read_failed, path, :file_changed_during_read}}

  defp parse_open_helper_result("E\t" <> _bounded_error, path),
    do: {:error, {:index_read_failed, path, :open_helper_failed}}

  defp parse_open_helper_result(_result, path),
    do: {:error, {:index_read_failed, path, :invalid_open_helper_response}}

  defp close_open_helper(port) do
    if Port.info(port) != nil, do: Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp open_and_read_index_worker_deadline(path, expected_identity) do
    reply_alias = :erlang.alias()

    # Non-Darwin OTP file APIs expose no portable no-follow/nonblocking flags.
    # This fallback bounds the caller, but deployments must keep the directory trusted.
    {pid, monitor_ref} =
      :erlang.spawn_opt(
        fn ->
          send(reply_alias, {reply_alias, open_and_read_index_worker(path, expected_identity)})
        end,
        [
          :monitor,
          {:max_heap_size, %{size: @index_reader_heap_words, kill: true, error_logger: false}}
        ]
      )

    receive do
      {^reply_alias, result} ->
        :erlang.unalias(reply_alias)
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        :erlang.unalias(reply_alias)
        {:error, {:index_read_failed, path, {:reader_exit, bounded_external_reason(reason)}}}
    after
      @index_read_deadline_ms ->
        :erlang.unalias(reply_alias)
        Process.exit(pid, :kill)
        Process.demonitor(monitor_ref, [:flush])
        {:error, {:index_read_failed, path, :read_deadline_exceeded}}
    end
  end

  defp open_and_read_index_worker(path, expected_identity) do
    case File.open(path, [:read, :binary], fn io ->
           read_verified_index(io, path, expected_identity)
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:index_read_failed, path, reason}}
    end
  end

  defp read_verified_index(io, path, expected_identity) do
    with {:ok, ^expected_identity} <- descriptor_identity(io),
         {:ok, body} <- read_bounded_index(io, path),
         {:ok, ^expected_identity} <- descriptor_identity(io),
         {:ok, ^expected_identity} <- index_path_identity(path) do
      {:ok, body}
    else
      {:ok, _changed_identity} ->
        {:error, {:index_read_failed, path, :file_changed_during_read}}

      {:error, {:opened_not_regular, type}} ->
        {:error, {:index_file_rejected, path, {:not_regular, type}}}

      {:error, _reason} = error ->
        error
    end
  end

  defp read_bounded_index(io, path) do
    case IO.binread(io, @max_index_bytes + 1) do
      :eof -> {:ok, ""}
      body when is_binary(body) and byte_size(body) <= @max_index_bytes -> {:ok, body}
      body when is_binary(body) -> {:error, {:index_size_exceeded, path, @max_index_bytes}}
      {:error, reason} -> {:error, {:index_read_failed, path, reason}}
    end
  end

  defp decode_index(path, body) do
    case Arbor.LLM.decode_bounded_json(body, @decoded_term_limits) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:index_decode_failed, path, bounded_external_reason(reason)}}
    end
  end

  defp normalize_index(path, %{"actions" => actions}) when is_list(actions) do
    case bounded_list_count(actions, @max_index_entries) do
      :exceeded ->
        {:error, {:invalid_index, path, {:entry_count_exceeded, @max_index_entries}}}

      {:ok, _action_count} ->
        actions
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {action, index}, {:ok, acc} ->
          case normalize_action(action) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            {:error, reason} -> {:halt, {:error, {:invalid_index, path, index, reason}}}
          end
        end)
        |> case do
          {:ok, []} ->
            {:error, {:invalid_index, path, :actions_required}}

          {:ok, normalized} ->
            normalized = Enum.reverse(normalized)

            case validate_index_dimensions(normalized) do
              :ok -> {:ok, normalized}
              {:error, reason} -> {:error, {:invalid_index, path, reason}}
            end

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp normalize_index(path, _index),
    do: {:error, {:invalid_index, path, :actions_required}}

  defp normalize_action(%{"module" => module} = action)
       when is_binary(module) and module != "" do
    description = Map.get(action, "description", "")
    embeddings = Map.get(action, "embeddings", %{})

    with {:ok, module} <- validate_index_string(module, :module, @max_module_bytes),
         :ok <- validate_description_type(description),
         {:ok, description} <-
           validate_index_string(description, :description, @max_description_bytes),
         :ok <- validate_embeddings_type(embeddings),
         {:ok, normalized} <- normalize_embeddings(embeddings) do
      {:ok, %{module: module, description: description, embeddings: normalized}}
    end
  end

  defp normalize_action(_action), do: {:error, :module_required}

  defp validate_description_type(description) when is_binary(description), do: :ok
  defp validate_description_type(_description), do: {:error, :description_must_be_string}

  defp validate_embeddings_type(embeddings) when is_map(embeddings), do: :ok
  defp validate_embeddings_type(_embeddings), do: {:error, :embeddings_must_be_object}

  defp normalize_embeddings(embeddings) do
    if map_size(embeddings) > @max_embedding_models do
      {:error, {:embedding_model_count_exceeded, @max_embedding_models}}
    else
      reduce_embeddings(embeddings)
    end
  end

  defp reduce_embeddings(embeddings) do
    Enum.reduce_while(embeddings, {:ok, %{}}, fn
      {model, vector}, {:ok, acc} when is_binary(model) ->
        with {:ok, model} <- validate_index_string(model, :model, @max_index_model_bytes),
             {:ok, _dimensions} <- validate_vector_values(vector) do
          {:cont, {:ok, Map.put(acc, model, vector)}}
        else
          {:error, {:field_bytes_exceeded, :model, _maximum} = reason} ->
            {:halt, {:error, {:invalid_embedding_model, reason}}}

          {:error, {:field_valid_utf8_required, :model} = reason} ->
            {:halt, {:error, {:invalid_embedding_model, reason}}}

          {:error, reason} ->
            {:halt, {:error, {:invalid_embedding, model, reason}}}
        end

      {_model, _vector}, _acc ->
        {:halt, {:error, {:invalid_embedding_model, :string_required}}}
    end)
  end

  defp bounded_list_count(list, maximum), do: bounded_list_count(list, maximum, 0)
  defp bounded_list_count(_list, maximum, count) when count > maximum, do: :exceeded
  defp bounded_list_count([], _maximum, count), do: {:ok, count}

  defp bounded_list_count([_head | tail], maximum, count),
    do: bounded_list_count(tail, maximum, count + 1)

  defp bounded_list_count(_improper, _maximum, _count), do: :exceeded

  defp diagnostic_excerpt(body) when is_binary(body) do
    {excerpt, truncated?} = bounded_binary_excerpt(body)
    %{body_excerpt: excerpt, truncated: truncated?}
  end

  defp diagnostic_excerpt(body) do
    rendered =
      body
      |> bounded_external_reason()
      |> inspect(
        limit: @max_external_items,
        printable_limit: @max_http_diagnostic_bytes,
        width: 80
      )

    {excerpt, _truncated?} = bounded_binary_excerpt(rendered)
    %{body_excerpt: excerpt, truncated: true}
  end

  defp bounded_response_collector(maximum) do
    fn {:data, data}, {request, response} when is_binary(data) ->
      retained = Map.get(response.private, :arbor_eval_response_bytes, 0)
      remaining = maximum - retained

      if byte_size(data) > remaining do
        prefix = if remaining > 0, do: binary_part(data, 0, remaining), else: ""

        private =
          response.private
          |> append_response_chunk(prefix)
          |> Map.put(:arbor_eval_response_overflow, true)

        response = %{
          response
          | body: "",
            private: private
        }

        {:halt, {request, response}}
      else
        private = append_response_chunk(response.private, data)
        {:cont, {request, %{response | body: "", private: private}}}
      end
    end
  end

  defp append_response_chunk(private, ""), do: private

  defp append_response_chunk(private, data) do
    private
    |> Map.update(:arbor_eval_response_chunks, [data], &[data | &1])
    |> Map.update(:arbor_eval_response_bytes, byte_size(data), &(&1 + byte_size(data)))
  end

  defp collected_response_body(%Req.Response{
         private: %{arbor_eval_response_chunks: chunks}
       })
       when is_list(chunks),
       do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp collected_response_body(%Req.Response{body: body}), do: {:ok, body}

  defp success_json_content_type(_response, body) when not is_binary(body), do: :ok
  defp success_json_content_type(response, _body), do: json_content_type(response)

  defp decode_error_body(response, body, maximum) when is_binary(body) do
    cond do
      byte_size(body) > maximum ->
        {:error, {:decoded_term_limit_exceeded, :bytes, maximum}}

      json_content_type(response) == :ok ->
        case decode_bounded_json_body(body, maximum) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _reason} -> {:ok, body}
        end

      true ->
        {:ok, body}
    end
  end

  defp decode_error_body(_response, body, maximum),
    do: decode_bounded_json_body(body, maximum)

  defp json_content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [] ->
        {:error, {:invalid_content_type, :application_json_required}}

      [value] ->
        if json_content_type?(value),
          do: :ok,
          else: {:error, {:invalid_content_type, :application_json_required}}

      _conflicting_or_malformed ->
        {:error, {:invalid_content_type, :application_json_required}}
    end
  end

  defp identity_content_encoding(response) do
    case Req.Response.get_header(response, "content-encoding") do
      [] ->
        :ok

      values ->
        if Enum.all?(values, &(String.downcase(String.trim(&1)) in ["", "identity"])),
          do: :ok,
          else: {:error, {:invalid_content_encoding, :identity_required}}
    end
  end

  defp json_content_type?(value) do
    media_type =
      value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    media_type == "application/json" or String.ends_with?(media_type, "+json")
  end

  defp decode_bounded_json_body(body, maximum) when is_binary(body) do
    limits = Keyword.put(@decoded_term_limits, :max_bytes, maximum)

    cond do
      byte_size(body) > maximum ->
        {:error, {:decoded_term_limit_exceeded, :bytes, maximum}}

      not String.valid?(body) ->
        {:error, {:invalid_json, :valid_utf8_required}}

      true ->
        case Arbor.LLM.decode_bounded_json(body, limits) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, {:invalid_json, :malformed}} -> {:ok, body}
          {:error, _reason} = error -> error
        end
    end
  end

  defp decode_bounded_json_body(body, maximum) do
    limits = Keyword.put(@decoded_term_limits, :max_bytes, maximum)

    case Arbor.LLM.validate_decoded_term(body, limits) do
      :ok -> {:ok, body}
      {:error, _reason} = error -> error
    end
  end

  defp bounded_binary_excerpt(value) do
    size = byte_size(value)
    prefix_size = min(size, @max_http_diagnostic_bytes)

    excerpt =
      value
      |> binary_part(0, prefix_size)
      |> String.replace_invalid("")

    {excerpt, size > @max_http_diagnostic_bytes}
  end

  defp bounded_utf8_prefix(_value, 0), do: ""

  defp bounded_utf8_prefix(value, maximum) do
    prefix_size = min(byte_size(value), maximum)

    value
    |> binary_part(0, prefix_size)
    |> String.replace_invalid("")
  end

  defp bound_term(_value, 0), do: :max_depth

  defp bound_term(value, _depth) when is_atom(value) or is_boolean(value) or is_nil(value),
    do: value

  defp bound_term(value, _depth) when is_integer(value) do
    if value >= @min_protocol_integer and value <= @max_protocol_integer,
      do: value,
      else: :integer_out_of_range
  end

  defp bound_term(value, _depth) when is_float(value) do
    if Arbor.LLM.finite_number?(value), do: value, else: :float_out_of_range
  end

  defp bound_term(value, _depth) when is_binary(value) do
    if byte_size(value) <= @max_external_diagnostic_bytes do
      String.replace_invalid(value, "")
    else
      {:truncated_binary, bounded_utf8_prefix(value, @max_external_diagnostic_bytes),
       byte_size(value)}
    end
  end

  defp bound_term(value, depth) when is_tuple(value) do
    count = min(tuple_size(value), @max_external_items)

    items =
      if count == 0 do
        []
      else
        Enum.map(0..(count - 1), &bound_term(elem(value, &1), depth - 1))
      end

    items = if tuple_size(value) > count, do: items ++ [:truncated], else: items
    List.to_tuple(items)
  end

  defp bound_term(value, depth) when is_list(value),
    do: bound_list(value, depth - 1, @max_external_items, [])

  defp bound_term(value, depth) when is_map(value),
    do: bound_map(:maps.iterator(value), depth - 1, @max_external_items, %{})

  defp bound_term(value, _depth) when is_pid(value), do: :pid
  defp bound_term(value, _depth) when is_reference(value), do: :reference
  defp bound_term(value, _depth) when is_function(value), do: :function
  defp bound_term(value, _depth) when is_port(value), do: :port
  defp bound_term(_value, _depth), do: :external_term

  defp bound_list([], _depth, _remaining, acc), do: Enum.reverse(acc)
  defp bound_list(_list, _depth, 0, acc), do: Enum.reverse([:truncated | acc])

  defp bound_list([head | tail], depth, remaining, acc),
    do: bound_list(tail, depth, remaining - 1, [bound_term(head, depth) | acc])

  defp bound_list(_tail, _depth, _remaining, acc), do: Enum.reverse([:improper_tail | acc])

  defp bound_map(iterator, depth, remaining, acc) do
    case :maps.next(iterator) do
      :none ->
        acc

      {_key, _value, _next} when remaining == 0 ->
        Map.put(acc, :__truncated__, true)

      {key, value, next} ->
        bound_map(
          next,
          depth,
          remaining - 1,
          Map.put(acc, bound_term(key, depth), bound_term(value, depth))
        )
    end
  end

  defp exception_diagnostic(%{__struct__: _module, message: message}) when is_binary(message),
    do: {:exception, bound_term(message, 1)}

  defp exception_diagnostic(%{__struct__: module}), do: {:exception, module}
  defp exception_diagnostic(_exception), do: :exception

  defp validate_vector_values([head | tail]), do: validate_vector_cell(head, tail, 0)
  defp validate_vector_values(_vector), do: {:error, :numeric_vector_required}

  defp validate_vector_cell(_head, _tail, dimensions)
       when dimensions >= @max_vector_dimensions,
       do: {:error, {:vector_dimensions_exceeded, @max_vector_dimensions}}

  defp validate_vector_cell(head, tail, dimensions) do
    if valid_vector_component?(head) do
      validate_vector_tail(tail, dimensions + 1)
    else
      {:error, :numeric_vector_required}
    end
  end

  defp validate_vector_tail([], dimensions), do: {:ok, dimensions}

  defp validate_vector_tail([head | tail], dimensions),
    do: validate_vector_cell(head, tail, dimensions)

  defp validate_vector_tail(_improper, _dimensions), do: {:error, :proper_vector_required}

  defp valid_vector_component?(value) when is_integer(value),
    do:
      value >= @min_protocol_integer and value <= @max_protocol_integer and
        value >= -@max_vector_component_abs and value <= @max_vector_component_abs

  defp valid_vector_component?(value) when is_float(value),
    do:
      Arbor.LLM.finite_number?(value) and value >= -@max_vector_component_abs and
        value <= @max_vector_component_abs

  defp valid_vector_component?(_value), do: false

  defp router_term_limits do
    @decoded_term_limits
    |> Keyword.put(:max_bytes, @max_router_response_bytes)
    |> Keyword.put(:max_nodes, 10_000)
    |> Keyword.put(:max_list_items, 1_000)
  end

  defp validate_index_dimensions(actions) do
    Enum.reduce_while(actions, {:ok, %{}}, fn action, {:ok, dimensions_by_model} ->
      case merge_embedding_dimensions(action.embeddings, dimensions_by_model) do
        {:ok, dimensions_by_model} -> {:cont, {:ok, dimensions_by_model}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _dimensions_by_model} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp merge_embedding_dimensions(embeddings, dimensions_by_model) do
    Enum.reduce_while(embeddings, {:ok, dimensions_by_model}, fn {model, vector}, {:ok, acc} ->
      dimensions = length(vector)

      case Map.fetch(acc, model) do
        :error ->
          {:cont, {:ok, Map.put(acc, model, dimensions)}}

        {:ok, ^dimensions} ->
          {:cont, {:ok, acc}}

        {:ok, expected} ->
          {:halt, {:error, {:inconsistent_embedding_dimensions, model, expected, dimensions}}}
      end
    end)
  end
end

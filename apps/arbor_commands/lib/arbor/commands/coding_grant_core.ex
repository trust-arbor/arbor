defmodule Arbor.Commands.CodingGrantCore do
  @moduledoc """
  Pure state machine for the operator coding-grant loop.

  `new/1` constructs state. `step/2` is a pure transition that returns the next
  state plus one effect as data. `show/1` formats a halt result. The core never
  receives or invokes callbacks; every decision is a data transition.
  """

  alias Arbor.Contracts.Security.CapabilityUri

  @default_max_rounds 5
  @min_max_rounds 1
  @max_max_rounds 20
  @max_findings 64
  @max_uris 1024
  @horizon_path ["planes", "executor", "details", "projection", "authority_horizon"]
  @allowed_opt_keys [:max_rounds, :dry_run]
  @state_keys [:max_rounds, :dry_run, :rounds, :granted, :failed, :remaining, :queue, :phase]

  @type effect ::
          :readiness
          | {:grant, String.t()}
          | {:emit, String.t()}
          | {:halt, result()}

  @type result :: %{
          status: atom(),
          rounds: non_neg_integer(),
          granted: [String.t()],
          failed: [{String.t(), term()}],
          remaining: [String.t()]
        }

  @doc """
  Construct grant-loop state.

  Allowed options: `:max_rounds` (1..20, default 5) and `:dry_run` (boolean,
  default false). Invalid `:max_rounds` is `{:error, :invalid_max_rounds}`;
  any other bad option is `{:error, :invalid_options}`.
  """
  @spec new(keyword() | map()) :: {:ok, map()} | {:error, atom()}
  def new(opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_options}

      extra_option_keys?(opts) ->
        {:error, :invalid_options}

      not valid_dry_run?(Keyword.get(opts, :dry_run, false)) ->
        {:error, :invalid_options}

      true ->
        case normalize_max_rounds(Keyword.get(opts, :max_rounds, @default_max_rounds)) do
          {:ok, max_rounds} ->
            {:ok, initial_state(max_rounds, Keyword.get(opts, :dry_run, false))}

          {:error, :invalid_max_rounds} = error ->
            error
        end
    end
  end

  def new(opts) when is_map(opts) and not is_struct(opts) do
    new(Map.to_list(opts))
  end

  def new(_opts), do: {:error, :invalid_options}

  @doc """
  Advance the machine. `max_rounds` is re-checked on every call, including
  preconstructed state.
  """
  @spec step(map(), {:readiness, term()} | {:grant_result, term(), :ok | {:error, term()}}) ::
          {map(), effect()}
  def step(state, input) when is_map(state) do
    case normalize_max_rounds(Map.get(state, :max_rounds)) do
      {:ok, max_rounds} ->
        dispatch(normalize_state(state, max_rounds), input)

      {:error, :invalid_max_rounds} ->
        halt(normalize_state(state, @default_max_rounds), :invalid_max_rounds)
    end
  end

  def step(state, _input) do
    halt(initial_state(@default_max_rounds, false), :invalid_options, carried(state))
  end

  @doc "Format a halt result for operator output."
  @spec show(result() | map()) :: String.t()
  def show(result) when is_map(result) do
    status = Map.get(result, :status, :invalid_options)
    rounds = Map.get(result, :rounds, 0)
    granted = Map.get(result, :granted, [])
    failed = Map.get(result, :failed, [])
    remaining = Map.get(result, :remaining, [])

    Enum.join(
      [
        "coding grant: #{status}",
        "rounds: #{rounds}",
        "granted: #{format_uris(granted)}",
        "failed: #{format_failed(failed)}",
        "remaining: #{format_uris(remaining)}"
      ],
      "\n"
    )
  end

  def show(_result), do: show(%{status: :invalid_options})

  defp extra_option_keys?(opts) do
    opts
    |> Keyword.keys()
    |> Enum.any?(fn key -> key not in @allowed_opt_keys end)
  end

  defp valid_dry_run?(dry_run), do: is_boolean(dry_run)

  defp normalize_max_rounds(max_rounds)
       when is_integer(max_rounds) and max_rounds >= @min_max_rounds and
              max_rounds <= @max_max_rounds do
    {:ok, max_rounds}
  end

  defp normalize_max_rounds(_max_rounds), do: {:error, :invalid_max_rounds}

  defp initial_state(max_rounds, dry_run) do
    %{
      max_rounds: max_rounds,
      dry_run: dry_run == true,
      rounds: 0,
      granted: [],
      failed: [],
      remaining: [],
      queue: [],
      phase: :idle
    }
  end

  defp normalize_state(state, max_rounds) do
    defaults = initial_state(max_rounds, false)

    Enum.reduce(@state_keys, defaults, fn key, acc ->
      Map.put(acc, key, Map.get(state, key, Map.fetch!(defaults, key)))
    end)
    |> Map.put(:max_rounds, max_rounds)
    |> Map.put(:dry_run, Map.get(state, :dry_run, false) == true)
    |> Map.put(:granted, list_or(Map.get(state, :granted), []))
    |> Map.put(:failed, list_or(Map.get(state, :failed), []))
    |> Map.put(:remaining, list_or(Map.get(state, :remaining), []))
    |> Map.put(:queue, list_or(Map.get(state, :queue), []))
    |> Map.put(:rounds, non_neg_or(Map.get(state, :rounds), 0))
  end

  defp list_or(value, _default) when is_list(value), do: value
  defp list_or(_value, default), do: default

  defp non_neg_or(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_neg_or(_value, default), do: default

  defp dispatch(state, {:readiness, report}), do: on_readiness(state, report)
  defp dispatch(state, {:grant_result, uri, result}), do: on_grant_result(state, uri, result)
  defp dispatch(state, _input), do: halt(state, :invalid_options)

  defp on_readiness(state, report) do
    next_rounds = state.rounds + 1

    cond do
      next_rounds > state.max_rounds ->
        halt(state, :unconverged, remaining: state.remaining)

      true ->
        state = %{state | rounds: next_rounds, queue: [], remaining: []}
        admit_readiness(state, report)
    end
  end

  defp admit_readiness(state, report) do
    case extract_caller_missing_uris(report) do
      {:ok, []} ->
        halt(state, :converged)

      {:ok, uris} ->
        decide_named_uris(state, uris)

      {:error, status} when status in [:malformed_report, :report_truncated] ->
        halt(state, status)

      {:error, :invalid_options} ->
        halt(state, :invalid_options)
    end
  end

  defp decide_named_uris(state, uris) do
    cond do
      state.rounds >= state.max_rounds and state.dry_run ->
        emit_named(state, uris, :halt)

      state.rounds >= state.max_rounds ->
        halt(state, :unconverged, remaining: uris)

      state.dry_run ->
        emit_named(state, uris, :continue)

      true ->
        grant_next(%{state | queue: uris, remaining: uris, phase: :granting})
    end
  end

  defp emit_named(state, uris, follow) do
    next_phase = if follow == :halt, do: :after_emit_halt, else: :after_emit
    state = %{state | remaining: uris, queue: [], phase: next_phase}
    {state, {:emit, format_uris(uris)}}
  end

  defp on_grant_result(%{phase: :after_emit} = state, _uri, _result) do
    {%{state | phase: :awaiting_readiness, remaining: []}, :readiness}
  end

  defp on_grant_result(%{phase: :after_emit_halt} = state, _uri, _result) do
    halt(state, :unconverged, remaining: state.remaining)
  end

  defp on_grant_result(%{phase: :granting, queue: [uri | rest]} = state, uri, :ok) do
    state = %{state | granted: state.granted ++ [uri], queue: rest, remaining: rest}
    next_after_grant(state)
  end

  defp on_grant_result(%{phase: :granting, queue: [uri | rest]} = state, uri, {:error, reason}) do
    halt(state, :grant_failed, failed: state.failed ++ [{uri, reason}], remaining: rest)
  end

  defp on_grant_result(state, uri, {:error, reason}) do
    halt(state, :grant_failed, failed: state.failed ++ [{to_string_uri(uri), reason}])
  end

  defp on_grant_result(state, _uri, _result) do
    halt(state, :grant_failed, remaining: remaining_or_queue(state))
  end

  defp next_after_grant(%{queue: []} = state) do
    {%{state | phase: :awaiting_readiness, remaining: []}, :readiness}
  end

  defp next_after_grant(state), do: grant_next(state)

  defp grant_next(%{queue: [uri | _rest]} = state) do
    {state, {:grant, uri}}
  end

  defp grant_next(state) do
    {%{state | phase: :awaiting_readiness}, :readiness}
  end

  defp extract_caller_missing_uris(report) do
    horizon = horizon_projection(report)

    case horizon do
      %{"findings" => findings, "required_resources" => required} when is_list(findings) ->
        with :ok <- validate_required_resources(required) do
          reduce_findings(findings)
        end

      _other ->
        {:error, :malformed_report}
    end
  end

  defp horizon_projection(report) when is_map(report) do
    get_in(report, @horizon_path)
  end

  defp horizon_projection(_report), do: nil

  defp validate_required_resources(required) when is_list(required), do: :ok

  defp validate_required_resources(%{"resource_uris" => uris}) when is_list(uris), do: :ok

  defp validate_required_resources(_required), do: {:error, :malformed_report}

  defp reduce_findings(findings) do
    findings
    |> Enum.reduce_while({:ok, [], 0, 0}, &consume_finding_budget/2)
    |> unwrap_extraction()
  end

  defp consume_finding_budget(_finding, {:ok, _uris, finding_count, _uri_count})
       when finding_count >= @max_findings do
    {:halt, {:error, :report_truncated}}
  end

  defp consume_finding_budget(finding, {:ok, uris, finding_count, uri_count}) do
    case consume_finding(finding, uris, uri_count) do
      {:ok, next_uris, next_uri_count} ->
        {:cont, {:ok, next_uris, finding_count + 1, next_uri_count}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp consume_finding(finding, uris, uri_count) when not is_map(finding) do
    _ = {uris, uri_count}
    {:error, :malformed_report}
  end

  defp consume_finding(finding, uris, uri_count) do
    if caller_missing?(finding) do
      take_caller_uris(finding, uris, uri_count)
    else
      {:ok, uris, uri_count}
    end
  end

  defp caller_missing?(finding) do
    Map.get(finding, "principal_role") == "authenticated_caller" and
      Map.get(finding, "classification") == "missing"
  end

  defp take_caller_uris(finding, uris, uri_count) do
    case Map.get(finding, "resource_uris") do
      list when is_list(list) ->
        append_valid_uris(list, uris, uri_count)

      _other ->
        {:error, :malformed_report}
    end
  end

  defp append_valid_uris(list, uris, uri_count) do
    Enum.reduce_while(list, {:ok, uris, uri_count}, &consume_uri_budget/2)
  end

  defp consume_uri_budget(_uri, {:ok, _uris, uri_count}) when uri_count >= @max_uris do
    {:halt, {:error, :report_truncated}}
  end

  defp consume_uri_budget(uri, {:ok, uris, uri_count}) do
    case admit_uri(uri) do
      {:ok, admitted} ->
        {:cont, {:ok, uris ++ [admitted], uri_count + 1}}

      {:error, :malformed_report} = error ->
        {:halt, error}
    end
  end

  defp admit_uri(uri) when is_binary(uri) do
    case CapabilityUri.parse(uri) do
      {:ok, parsed} ->
        if wildcard_or_root?(parsed) do
          {:error, :malformed_report}
        else
          {:ok, uri}
        end

      {:error, _reason} ->
        {:error, :malformed_report}
    end
  end

  defp admit_uri(_uri), do: {:error, :malformed_report}

  defp wildcard_or_root?(parsed) do
    parsed.wildcard != :none or parsed.segments == ["**"]
  end

  defp unwrap_extraction({:ok, uris, _finding_count, _uri_count}), do: {:ok, uris}
  defp unwrap_extraction({:error, _reason} = error), do: error

  defp halt(state, status, overrides \\ []) do
    result = %{
      status: status,
      rounds: reported_rounds(state),
      granted: Keyword.get(overrides, :granted, state.granted),
      failed: Keyword.get(overrides, :failed, state.failed),
      remaining: Keyword.get(overrides, :remaining, state.remaining)
    }

    {%{state | phase: :halted, remaining: result.remaining, failed: result.failed},
     {:halt, result}}
  end

  defp reported_rounds(state) do
    max_rounds =
      case normalize_max_rounds(Map.get(state, :max_rounds)) do
        {:ok, value} -> value
        {:error, :invalid_max_rounds} -> @max_max_rounds
      end

    min(non_neg_or(Map.get(state, :rounds), 0), max_rounds)
  end

  defp remaining_or_queue(%{queue: queue}) when is_list(queue) and queue != [], do: queue
  defp remaining_or_queue(%{remaining: remaining}) when is_list(remaining), do: remaining
  defp remaining_or_queue(_state), do: []

  defp carried(state) when is_map(state) do
    [
      granted: list_or(Map.get(state, :granted), []),
      failed: list_or(Map.get(state, :failed), []),
      remaining: list_or(Map.get(state, :remaining), [])
    ]
  end

  defp carried(_state), do: []

  defp to_string_uri(uri) when is_binary(uri), do: uri
  defp to_string_uri(uri), do: inspect(uri)

  defp format_uris([]), do: "(none)"
  defp format_uris(uris), do: Enum.join(uris, "\n")

  defp format_failed([]), do: "(none)"

  defp format_failed(failed) do
    Enum.map_join(failed, "\n", fn
      {uri, reason} -> "#{uri} (#{inspect(reason)})"
      other -> inspect(other)
    end)
  end
end

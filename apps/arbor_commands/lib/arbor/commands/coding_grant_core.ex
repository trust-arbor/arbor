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
  @projection_path ["planes", "executor", "details", "projection"]
  @allowed_opt_keys [:max_rounds, :dry_run]
  @state_keys [:max_rounds, :dry_run, :rounds, :granted, :failed, :remaining, :queue, :phase]
  @known_roles ["authenticated_caller", "execution_principal"]
  @plan_validation_codes [
    :invalid_object,
    :invalid_field,
    :invalid_field_type,
    :missing_field,
    :blank_field,
    :invalid_object_key
  ]
  @plan_validation_code_names Map.new(@plan_validation_codes, fn code ->
                                {Atom.to_string(code), code}
                              end)

  @type grant_target :: %{
          principal_role: String.t(),
          principal_id: String.t(),
          uri: String.t()
        }

  @type effect ::
          :readiness
          | {:grant, grant_target()}
          | {:emit, String.t()}
          | {:halt, result()}

  @type result :: %{
          status: atom() | {atom(), String.t()} | map(),
          rounds: non_neg_integer(),
          granted: [grant_target()],
          failed: [{grant_target(), term()}],
          remaining: [grant_target()]
        }

  @type state :: %{
          max_rounds: pos_integer(),
          dry_run: boolean(),
          rounds: non_neg_integer(),
          granted: [grant_target()],
          failed: [{grant_target(), term()}],
          remaining: [grant_target()],
          queue: [grant_target()],
          phase: atom()
        }

  @doc """
  Construct grant-loop state.

  Allowed options: `:max_rounds` (1..20, default 5) and `:dry_run` (boolean,
  default false). Invalid `:max_rounds` is `{:error, :invalid_max_rounds}`;
  any other bad option is `{:error, :invalid_options}`.
  """
  @spec new(keyword() | map()) :: {:ok, state()} | {:error, atom()}
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

  After an `{:emit, text}` effect, the shell must call `step/2` with any
  `{:grant_result, _, _}` to acknowledge the listing. Phases `:after_emit` and
  `:after_emit_halt` are listing-ack phases, not grant phases — the URI and
  result are ignored.
  """
  @spec step(
          state() | map(),
          {:readiness, term()} | {:grant_result, term(), :ok | {:error, term()}}
        ) ::
          {state(), effect()}
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
        status_line(status),
        "rounds: #{rounds}",
        format_section("granted", granted),
        "failed: #{format_failed(failed)}",
        format_section("remaining", remaining)
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
    |> Map.put(:granted, normalize_grant_list(list_or(Map.get(state, :granted), [])))
    |> Map.put(:failed, normalize_failed_list(list_or(Map.get(state, :failed), [])))
    |> Map.put(:remaining, normalize_grant_list(list_or(Map.get(state, :remaining), [])))
    |> Map.put(:queue, normalize_grant_list(list_or(Map.get(state, :queue), [])))
    |> Map.put(:rounds, non_neg_or(Map.get(state, :rounds), 0))
  end

  defp list_or(value, _default) when is_list(value), do: value
  defp list_or(_value, default), do: default

  defp non_neg_or(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_neg_or(_value, default), do: default

  defp normalize_grant_list(list), do: Enum.map(list, &normalize_grant_item/1)

  defp normalize_failed_list(list), do: Enum.map(list, &normalize_failed_item/1)

  defp normalize_grant_item(%{principal_role: role, principal_id: id, uri: uri})
       when is_binary(role) and is_binary(id) and is_binary(uri) do
    %{principal_role: role, principal_id: id, uri: uri}
  end

  defp normalize_grant_item(uri) when is_binary(uri) do
    %{principal_role: "authenticated_caller", principal_id: "", uri: uri}
  end

  defp normalize_grant_item(other) do
    %{principal_role: "authenticated_caller", principal_id: "", uri: to_string_uri(other)}
  end

  defp normalize_failed_item({item, reason}), do: {normalize_grant_item(item), reason}
  defp normalize_failed_item(item), do: {normalize_grant_item(item), :invalid}

  defp dispatch(state, {:readiness, report}), do: on_readiness(state, report)
  defp dispatch(state, {:grant_result, ack, result}), do: on_grant_result(state, ack, result)
  defp dispatch(state, _input), do: halt(state, :invalid_options)

  defp on_readiness(state, report) do
    next_rounds = state.rounds + 1

    if next_rounds > state.max_rounds do
      halt(state, :unconverged, remaining: state.remaining)
    else
      state = %{state | rounds: next_rounds, queue: [], remaining: []}
      admit_readiness(state, report)
    end
  end

  defp admit_readiness(state, report) do
    case extract_missing_targets(report) do
      {:ok, []} ->
        halt(state, :converged)

      {:ok, targets} ->
        decide_named_targets(state, targets)

      {:error, status} ->
        halt(state, status)
    end
  end

  defp decide_named_targets(state, targets) do
    cond do
      state.rounds >= state.max_rounds and state.dry_run ->
        emit_named(state, targets, :halt)

      state.rounds >= state.max_rounds ->
        halt(state, :unconverged, remaining: targets)

      state.dry_run ->
        emit_named(state, targets, :continue)

      true ->
        grant_next(%{state | queue: targets, remaining: targets, phase: :granting})
    end
  end

  defp emit_named(state, targets, follow) do
    next_phase = if follow == :halt, do: :after_emit_halt, else: :after_emit
    state = %{state | remaining: targets, queue: [], phase: next_phase}
    {state, {:emit, format_uri_list(targets)}}
  end

  # Listing ack after {:emit, text}. Not a grant: URI and result are ignored.
  defp on_grant_result(%{phase: :after_emit} = state, _ack, _result) do
    {%{state | phase: :awaiting_readiness, remaining: []}, :readiness}
  end

  defp on_grant_result(%{phase: :after_emit_halt} = state, _ack, _result) do
    halt(state, :unconverged, remaining: state.remaining)
  end

  defp on_grant_result(%{phase: :granting, queue: [target | rest]} = state, ack, :ok) do
    if same_grant?(target, ack) do
      next_after_grant(%{state | granted: [target | state.granted], queue: rest, remaining: rest})
    else
      halt(state, :grant_failed, remaining: remaining_or_queue(state))
    end
  end

  defp on_grant_result(%{phase: :granting, queue: [target | rest]} = state, ack, {:error, reason}) do
    if same_grant?(target, ack) do
      state = %{
        state
        | failed: [{target, reason} | state.failed],
          remaining: [target | rest]
      }

      halt(state, :grant_failed)
    else
      state = %{state | failed: [{coerce_failed_target(ack), reason} | state.failed]}
      halt(state, :grant_failed)
    end
  end

  defp on_grant_result(state, ack, {:error, reason}) do
    state = %{state | failed: [{coerce_failed_target(ack), reason} | state.failed]}
    halt(state, :grant_failed)
  end

  defp on_grant_result(state, _ack, _result) do
    halt(state, :grant_failed, remaining: remaining_or_queue(state))
  end

  defp same_grant?(target, ack) do
    grant_target?(target) and grant_target?(ack) and
      target.principal_role == ack.principal_role and
      target.principal_id == ack.principal_id and
      target.uri == ack.uri
  end

  defp grant_target?(%{principal_role: role, principal_id: id, uri: uri})
       when is_binary(role) and is_binary(id) and is_binary(uri) and id != "" do
    role in @known_roles
  end

  defp grant_target?(_other), do: false

  defp coerce_failed_target(ack) do
    if grant_target?(ack) do
      normalize_grant_item(ack)
    else
      normalize_grant_item(to_string_uri(ack))
    end
  end

  defp next_after_grant(%{queue: []} = state) do
    {%{state | phase: :awaiting_readiness, remaining: []}, :readiness}
  end

  defp next_after_grant(state), do: grant_next(state)

  defp grant_next(%{queue: [target | _rest]} = state) do
    if grant_target?(target) do
      {state, {:grant, target}}
    else
      halt(state, :malformed_report)
    end
  end

  defp grant_next(state) do
    {%{state | phase: :awaiting_readiness}, :readiness}
  end

  defp extract_missing_targets(report) do
    case fetch_map_path(report, @horizon_path) do
      %{"findings" => findings, "required_resources" => required} = horizon
      when is_list(findings) ->
        with :ok <- validate_required_resources(required) do
          reduce_findings(findings, named_principals(report, horizon))
        end

      _other ->
        case plan_validation_status(report) do
          {:ok, status} -> {:error, status}
          :error -> {:error, :malformed_report}
        end
    end
  end

  defp fetch_map_path(value, []) do
    value
  end

  defp fetch_map_path(value, [key | rest]) when is_map(value) and not is_struct(value) do
    case Map.fetch(value, key) do
      {:ok, next} -> fetch_map_path(next, rest)
      :error -> nil
    end
  end

  defp fetch_map_path(_value, _path), do: nil

  defp validate_required_resources(required) when is_list(required), do: :ok

  defp validate_required_resources(%{"resource_uris" => uris}) when is_list(uris), do: :ok

  defp validate_required_resources(_required), do: {:error, :malformed_report}

  defp named_principals(report, horizon) do
    projection = fetch_map_path(report, @projection_path)

    %{}
    |> put_principals_list(horizon)
    |> put_fallback("authenticated_caller", [
      map_get(report, "caller_id"),
      map_get(projection, "caller_id")
    ])
    |> put_fallback("execution_principal", [
      map_get(report, "agent_id"),
      map_get(projection, "agent_id")
    ])
  end

  defp put_principals_list(acc, %{"principals" => list}) when is_list(list) do
    Enum.reduce(list, acc, fn
      %{"role" => role, "principal_id" => id}, acc
      when role in @known_roles and is_binary(id) and id != "" ->
        Map.put_new(acc, role, id)

      _other, acc ->
        acc
    end)
  end

  defp put_principals_list(acc, _horizon), do: acc

  defp put_fallback(acc, role, candidates) do
    case Map.get(acc, role) do
      id when is_binary(id) and id != "" ->
        acc

      _missing ->
        case Enum.find(candidates, &(is_binary(&1) and &1 != "")) do
          nil -> acc
          id -> Map.put(acc, role, id)
        end
    end
  end

  defp map_get(map, key) when is_map(map) and not is_struct(map), do: Map.get(map, key)
  defp map_get(_map, _key), do: nil

  defp reduce_findings(findings, named) do
    findings
    |> Enum.reduce_while({:ok, [], 0, 0}, fn finding, acc ->
      consume_finding_budget(finding, acc, named)
    end)
    |> unwrap_extraction()
  end

  defp consume_finding_budget(_finding, {:ok, _targets, finding_count, _uri_count}, _named)
       when finding_count >= @max_findings do
    {:halt, {:error, :report_truncated}}
  end

  defp consume_finding_budget(finding, {:ok, targets, finding_count, uri_count}, named) do
    case consume_finding(finding, targets, uri_count, named) do
      {:ok, next_targets, next_uri_count} ->
        {:cont, {:ok, next_targets, finding_count + 1, next_uri_count}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp consume_finding(finding, targets, uri_count, named) when is_map(finding) do
    if known_role_missing?(finding) do
      case resolve_finding_principal(finding, named) do
        {:ok, role, principal_id} ->
          take_missing_uris(finding, targets, uri_count, role, principal_id)

        {:error, :malformed_report} = error ->
          error
      end
    else
      {:ok, targets, uri_count}
    end
  end

  defp consume_finding(_finding, _targets, _uri_count, _named) do
    {:error, :malformed_report}
  end

  defp known_role_missing?(finding) do
    Map.get(finding, "principal_role") in @known_roles and
      Map.get(finding, "classification") == "missing"
  end

  defp resolve_finding_principal(finding, named) do
    role = Map.get(finding, "principal_role")
    finding_id = present_id(Map.get(finding, "principal_id"))
    named_id = present_id(Map.get(named, role))

    cond do
      is_binary(finding_id) and is_binary(named_id) and finding_id != named_id ->
        {:error, :malformed_report}

      is_binary(finding_id) ->
        {:ok, role, finding_id}

      is_binary(named_id) ->
        {:ok, role, named_id}

      true ->
        {:error, :malformed_report}
    end
  end

  defp present_id(id) when is_binary(id) and id != "", do: id
  defp present_id(_id), do: nil

  defp take_missing_uris(finding, targets, uri_count, role, principal_id) do
    case Map.get(finding, "resource_uris") do
      list when is_list(list) ->
        append_valid_targets(list, targets, uri_count, role, principal_id)

      _other ->
        {:error, :malformed_report}
    end
  end

  defp append_valid_targets(list, targets, uri_count, role, principal_id) do
    Enum.reduce_while(list, {:ok, targets, uri_count}, fn uri, acc ->
      consume_uri_budget(uri, acc, role, principal_id)
    end)
  end

  defp consume_uri_budget(_uri, {:ok, _targets, uri_count}, _role, _principal_id)
       when uri_count >= @max_uris do
    {:halt, {:error, :report_truncated}}
  end

  defp consume_uri_budget(uri, {:ok, targets, uri_count}, role, principal_id) do
    case admit_uri(uri) do
      {:ok, admitted} ->
        target = %{principal_role: role, principal_id: principal_id, uri: admitted}
        {:cont, {:ok, [target | targets], uri_count + 1}}

      {:error, :malformed_report} = error ->
        {:halt, error}
    end
  end

  defp admit_uri(uri) when is_binary(uri) do
    case CapabilityUri.parse(uri) do
      {:ok, parsed} ->
        if unsafe_capability_uri?(parsed) do
          {:error, :malformed_report}
        else
          {:ok, uri}
        end

      {:error, _reason} ->
        {:error, :malformed_report}
    end
  end

  defp admit_uri(_uri), do: {:error, :malformed_report}

  defp unsafe_capability_uri?(parsed) do
    parsed.wildcard != :none or parsed.segments == ["**"] or ".." in parsed.segments
  end

  defp unwrap_extraction({:ok, targets, _finding_count, _uri_count}),
    do: {:ok, Enum.reverse(targets)}

  defp unwrap_extraction({:error, _reason} = error), do: error

  defp plan_validation_status(report) do
    projection = fetch_map_path(report, @projection_path)

    cond do
      match?({:ok, _}, verbatim_plan_validation(map_get(projection, "error"))) ->
        verbatim_plan_validation(map_get(projection, "error"))

      match?({:ok, _}, verbatim_plan_validation(map_get(report, "error"))) ->
        verbatim_plan_validation(map_get(report, "error"))

      true ->
        :error
    end
  end

  defp verbatim_plan_validation({code, field})
       when code in @plan_validation_codes and is_binary(field) and field != "" do
    {:ok, {code, field}}
  end

  defp verbatim_plan_validation(%{"code" => code} = error) do
    case plan_validation_code(code) do
      {:ok, atom} ->
        case plan_validation_field(error) do
          {:ok, field} -> {:ok, {atom, field}}
          :error -> {:ok, atom}
        end

      :error ->
        :error
    end
  end

  defp verbatim_plan_validation(_payload), do: :error

  defp plan_validation_code(code) when code in @plan_validation_codes, do: {:ok, code}

  defp plan_validation_code(code) when is_binary(code) do
    case Map.fetch(@plan_validation_code_names, code) do
      {:ok, atom} -> {:ok, atom}
      :error -> :error
    end
  end

  defp plan_validation_code(_code), do: :error

  defp plan_validation_field(error) when is_map(error) do
    Enum.find_value(["field", "path", "detail"], fn key ->
      case Map.get(error, key) do
        field when is_binary(field) and field != "" -> {:ok, field}
        _other -> nil
      end
    end) || :error
  end

  defp halt(state, status, overrides \\ []) do
    result = %{
      status: status,
      rounds: reported_rounds(state),
      granted: Enum.reverse(Keyword.get(overrides, :granted, state.granted)),
      failed: Enum.reverse(Keyword.get(overrides, :failed, state.failed)),
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
      granted: normalize_grant_list(list_or(Map.get(state, :granted), [])),
      failed: normalize_failed_list(list_or(Map.get(state, :failed), [])),
      remaining: normalize_grant_list(list_or(Map.get(state, :remaining), []))
    ]
  end

  defp carried(_state), do: []

  defp to_string_uri(uri) when is_binary(uri), do: uri
  defp to_string_uri(uri), do: inspect(uri)

  defp status_line(status) when is_atom(status), do: "coding grant: #{status}"
  defp status_line(status), do: "coding grant: #{inspect(status)}"

  defp format_section(label, items) do
    if items == [] or caller_only_items?(items) do
      "#{label}: #{format_uri_list(items)}"
    else
      "#{label}:\n#{format_uris_by_role(items)}"
    end
  end

  defp format_uri_list([]), do: "(none)"
  defp format_uri_list(items), do: Enum.map_join(items, "\n", &uri_of/1)

  defp format_uris_by_role(items) do
    grouped = Enum.group_by(items, &role_of/1)

    @known_roles
    |> Enum.filter(&(Map.get(grouped, &1, []) != []))
    |> Enum.map_join("\n", fn role ->
      role_items = Map.fetch!(grouped, role)
      principal_id = principal_id_of(hd(role_items))
      uris = Enum.map_join(role_items, "\n", &uri_of/1)
      "#{role} (#{principal_id}):\n#{uris}"
    end)
  end

  defp format_failed([]), do: "(none)"

  defp format_failed(failed) do
    if caller_only_failed?(failed) do
      Enum.map_join(failed, "\n", &format_caller_failed/1)
    else
      Enum.map_join(failed, "\n", &format_role_failed/1)
    end
  end

  defp format_caller_failed({item, reason}), do: "#{uri_of(item)} (#{inspect(reason)})"
  defp format_caller_failed(other), do: inspect(other)

  defp format_role_failed({item, reason}) do
    "#{role_of(item)} #{principal_id_of(item)} #{uri_of(item)} (#{inspect(reason)})"
  end

  defp format_role_failed(other), do: inspect(other)

  defp caller_only_items?(items) when is_list(items), do: Enum.all?(items, &caller_item?/1)
  defp caller_only_failed?(failed) when is_list(failed), do: Enum.all?(failed, &caller_failed?/1)

  defp caller_failed?({item, _reason}), do: caller_item?(item)
  defp caller_failed?(item), do: caller_item?(item)

  defp caller_item?(uri) when is_binary(uri), do: true
  defp caller_item?(%{principal_role: "authenticated_caller"}), do: true
  defp caller_item?(_other), do: false

  defp uri_of(%{uri: uri}) when is_binary(uri), do: uri
  defp uri_of(uri) when is_binary(uri), do: uri
  defp uri_of(other), do: to_string_uri(other)

  defp role_of(%{principal_role: role}) when is_binary(role), do: role
  defp role_of(_other), do: "authenticated_caller"

  defp principal_id_of(%{principal_id: id}) when is_binary(id), do: id
  defp principal_id_of(_other), do: ""
end

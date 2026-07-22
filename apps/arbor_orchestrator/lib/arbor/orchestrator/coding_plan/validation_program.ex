defmodule Arbor.Orchestrator.CodingPlan.ValidationProgram do
  @moduledoc """
  Builds the closed, versioned validation program selected by a coding profile.

  A validation program is pure JSON-clean data. It selects one existing Jido
  action and describes its context bindings, result adapter, and static
  parameters; it does not execute or adapt action results.
  """

  alias Arbor.Orchestrator.CodingPlan.Profiles

  @version 1
  @selection_by_profile %{
    "cross_app" => %{
      "action" => "coding_cross_app_validate",
      "result_adapter" => "cross_app_v1"
    },
    "default" => %{
      "action" => "mix_compile",
      "result_adapter" => "mix_compile_v1"
    },
    "security_regression" => %{
      "action" => "coding_security_regression_validate",
      "result_adapter" => "security_regression_v1"
    }
  }
  @profile_ids_by_action Map.new(@selection_by_profile, fn {profile_id, selection} ->
                           {selection["action"], profile_id}
                         end)
  @result_adapters @selection_by_profile
                   |> Map.values()
                   |> Enum.map(& &1["result_adapter"])
  @descriptor_keys Enum.sort(~w[
                     action
                     context_keys
                     profile_id
                     result_adapter
                     static_parameters
                     version
                   ])

  @type json_value ::
          nil | boolean() | number() | String.t() | [json_value()] | %{String.t() => json_value()}
  @type descriptor :: %{String.t() => json_value()}
  @type build_error ::
          :invalid_validation_budget
          | :invalid_validation_program
          | :invalid_validation_strategy
          | {:unsupported_validation_strategy, term()}
          | :invalid_validation_timeout_policy
          | :invalid_validation_test_stage_timeout_policy

  @doc "Returns the canonical validation program version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Builds a validation program from a reviewed strategy and plan budgets."
  @spec build(map(), map()) :: {:ok, descriptor()} | {:error, build_error()}
  def build(strategy, budgets) when is_map(strategy) do
    with {:ok, profile_id} <- profile_id_for_strategy(strategy),
         {:ok, canonical_strategy} <- canonical_strategy(profile_id),
         :ok <- require_canonical_strategy(strategy, canonical_strategy),
         {:ok, wall_clock_ms} <- fetch_wall_clock_budget(budgets),
         profile = %{"validation_strategy" => strategy},
         {:ok, timeout_ms} <- Profiles.validation_timeout(profile, wall_clock_ms),
         {:ok, test_stage_timeout_ms} <-
           Profiles.validation_test_stage_timeout(profile, wall_clock_ms) do
      static_parameters =
        strategy["static_parameters"]
        |> Map.put("timeout", timeout_ms)
        |> maybe_put_test_stage_timeout(test_stage_timeout_ms)

      program = %{
        "version" => @version,
        "profile_id" => profile_id,
        "action" => strategy["action"],
        "result_adapter" => strategy["result_adapter"],
        "context_keys" => strategy["context_keys"],
        "static_parameters" => static_parameters
      }

      case validate(program) do
        :ok -> {:ok, program}
        {:error, _reason} = error -> error
      end
    end
  end

  def build(_strategy, _budgets), do: {:error, :invalid_validation_strategy}

  @doc "Projects a validated program onto the existing validation exec node."
  @spec project_onto(descriptor(), map()) ::
          {:ok, %{String.t() => term()}} | {:error, :invalid_validation_program}
  def project_onto(program, attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- validate(program) do
      controlled_attrs =
        %{
          "action" => program["action"],
          "context_keys" => Enum.join(program["context_keys"], ","),
          "output_prefix" => result_prefix(program["result_adapter"])
        }
        |> put_static_parameters(program["static_parameters"])

      attrs =
        attrs
        |> Enum.reject(fn {key, _value} -> static_parameter_attr?(key) end)
        |> Map.new()
        |> Map.merge(controlled_attrs)

      {:ok, attrs}
    end
  end

  def project_onto(_program, _attrs), do: {:error, :invalid_validation_program}

  @doc "Validates a validation program as closed, versioned JSON-clean data."
  @spec validate(term()) :: :ok | {:error, :invalid_validation_program}
  def validate(program) when is_map(program) and not is_struct(program) do
    with true <- Enum.sort(Map.keys(program)) == @descriptor_keys,
         @version <- program["version"],
         profile_id when is_binary(profile_id) <- program["profile_id"],
         action when is_binary(action) <- program["action"],
         ^profile_id <- Map.get(@profile_ids_by_action, action),
         adapter when is_binary(adapter) <- program["result_adapter"],
         true <- valid_selection?(profile_id, action, adapter),
         context_keys when is_list(context_keys) <- program["context_keys"],
         true <- valid_context_keys?(profile_id, context_keys),
         static_parameters when is_map(static_parameters) and not is_struct(static_parameters) <-
           program["static_parameters"],
         true <- valid_static_parameters?(profile_id, static_parameters),
         {:ok, _encoded} <- Jason.encode(program) do
      :ok
    else
      _other -> {:error, :invalid_validation_program}
    end
  end

  def validate(_program), do: {:error, :invalid_validation_program}

  defp profile_id_for_strategy(%{"action" => action}) when is_binary(action) do
    case Map.fetch(@profile_ids_by_action, action) do
      {:ok, profile_id} -> {:ok, profile_id}
      :error -> {:error, {:unsupported_validation_strategy, action}}
    end
  end

  defp profile_id_for_strategy(%{"required_enforcement" => enforcement}),
    do: {:error, {:unsupported_validation_strategy, enforcement}}

  defp profile_id_for_strategy(_strategy), do: {:error, :invalid_validation_strategy}

  defp canonical_strategy(profile_id) do
    case Profiles.fetch_executable(profile_id) do
      {:ok, profile} -> {:ok, profile["validation_strategy"]}
      {:error, _reason} -> {:error, :invalid_validation_strategy}
    end
  end

  defp require_canonical_strategy(strategy, strategy), do: :ok

  defp require_canonical_strategy(_strategy, _canonical),
    do: {:error, :invalid_validation_strategy}

  defp fetch_wall_clock_budget(%{"wall_clock_ms" => wall_clock_ms})
       when is_integer(wall_clock_ms) and wall_clock_ms > 0,
       do: {:ok, wall_clock_ms}

  defp fetch_wall_clock_budget(_budgets), do: {:error, :invalid_validation_budget}

  defp maybe_put_test_stage_timeout(parameters, nil), do: parameters

  defp maybe_put_test_stage_timeout(parameters, timeout_ms),
    do: Map.put(parameters, "test_stage_timeout", timeout_ms)

  defp valid_context_keys?("default", context_keys),
    do: context_keys == ["path", "workspace_id"]

  defp valid_context_keys?("cross_app", context_keys), do: context_keys == ["workspace_id"]

  defp valid_context_keys?("security_regression", context_keys),
    do: context_keys == ["review_attestation_id"]

  defp valid_context_keys?(_profile_id, _context_keys), do: false

  defp valid_selection?(profile_id, action, adapter) do
    Map.get(@selection_by_profile, profile_id) == %{
      "action" => action,
      "result_adapter" => adapter
    }
  end

  defp valid_static_parameters?(
         "default",
         %{"timeout" => timeout_ms, "warnings_as_errors" => true} = params
       )
       when map_size(params) == 2,
       do: valid_timeout?("default", timeout_ms)

  defp valid_static_parameters?("security_regression", %{"timeout" => timeout_ms} = params)
       when map_size(params) == 1,
       do: valid_timeout?("security_regression", timeout_ms)

  defp valid_static_parameters?(
         "cross_app",
         %{"test_stage_timeout" => test_stage_timeout_ms, "timeout" => timeout_ms} = params
       )
       when map_size(params) == 2 do
    with {:ok, strategy} <- canonical_strategy("cross_app") do
      timeout_max_ms = strategy["timeout_max_ms"]
      test_stage_timeout_max_ms = strategy["test_stage_timeout_max_ms"]

      is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= timeout_max_ms and
        is_integer(test_stage_timeout_ms) and test_stage_timeout_ms >= timeout_ms and
        test_stage_timeout_ms <= test_stage_timeout_max_ms and
        (timeout_ms == timeout_max_ms or test_stage_timeout_ms == timeout_ms)
    else
      _error -> false
    end
  end

  defp valid_static_parameters?(_profile_id, _parameters), do: false

  defp valid_timeout?(profile_id, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, strategy} <- canonical_strategy(profile_id) do
      timeout_ms <= strategy["timeout_max_ms"]
    else
      _error -> false
    end
  end

  defp valid_timeout?(_profile_id, _timeout_ms), do: false

  defp result_prefix(adapter) when adapter in @result_adapters, do: "validation"

  defp put_static_parameters(attrs, parameters) do
    parameters
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(attrs, fn {name, value}, projected ->
      Map.put(projected, "param.#{name}", value)
    end)
  end

  defp static_parameter_attr?("param." <> _name), do: true
  defp static_parameter_attr?("arg." <> _name), do: true
  defp static_parameter_attr?(_key), do: false
end

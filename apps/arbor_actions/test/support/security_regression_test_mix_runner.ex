defmodule Arbor.Actions.SecurityRegressionTestMixRunner do
  @moduledoc """
  Test-only Mix runner for `SecurityRegression.Shell`.

  Production `SecurityRegression.Shell` defaults to `Arbor.Actions.Mix.run_mix/3`,
  which correctly fails closed with `:mix_wrapper_unavailable` when BEAM ancestry
  cannot prove the reviewed host wrapper (for example under an external
  `MIX_BUILD_PATH`). This suite installs that shell's
  `:security_regression_mix_runner` seam so two-revision fixtures stay hermetic
  without weakening production wrapper resolution.

  Behavioral contracts preserved here match production `run_mix/3` for the
  paths this suite exercises:

  * derive revision-private contained Mix env from the validation resource
  * bind the committable Git tree before and after the command
  * fail closed with `:validation_tree_mutated` when the tree changes
  * return validated tree/head evidence on success

  Execution itself goes through `Arbor.Actions.TestMixShell` so the finite
  fixture never requires Apple Container admission.
  """

  alias Arbor.Actions.Mix, as: MixAction
  alias Arbor.Actions.TestMixShell

  @spec run(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, args, opts)
      when is_binary(path) and is_list(args) and is_list(opts) do
    resource = Keyword.get(opts, :validation_resource)

    if is_nil(resource) or not is_map(resource) do
      {:error, :validation_resource_required}
    else
      do_run(path, args, opts)
    end
  end

  def run(_path, _args, _opts), do: {:error, :invalid_mix_invocation}

  defp do_run(path, args, opts) do
    revision = Keyword.get(opts, :validation_revision, :candidate)
    bind_tree? = Keyword.get(opts, :bind_committable_tree, true)
    timeout = Keyword.get(opts, :timeout, 120_000)
    deadline_ms = Keyword.get(opts, :deadline_ms) || absolute_deadline(timeout)

    env_opts =
      [
        validation_resource: Keyword.get(opts, :validation_resource),
        validation_revision: revision,
        project_path: path,
        env: Keyword.get(opts, :env, %{}),
        default_env: Keyword.get(opts, :default_env, %{})
      ]

    with {:ok, env} <- MixAction.contained_mix_env(env_opts),
         {:ok, before_binding} <- maybe_tree_binding(path, bind_tree?, deadline_ms),
         {:ok, result} <-
           TestMixShell.execute_spawn_capable("mix", args,
             cwd: path,
             env: env
           ),
         {:ok, after_binding} <- maybe_tree_binding(path, bind_tree?, deadline_ms),
         :ok <- assert_tree_stable(before_binding, after_binding) do
      {:ok, attach_binding_evidence(result, before_binding)}
    end
  end

  defp maybe_tree_binding(_path, false, _deadline_ms), do: {:ok, nil}

  defp maybe_tree_binding(path, true, deadline_ms) do
    MixAction.committable_tree_binding(path, deadline_ms: deadline_ms)
  end

  defp assert_tree_stable(nil, nil), do: :ok

  defp assert_tree_stable(%{tree_oid: before}, %{tree_oid: after_oid})
       when before == after_oid,
       do: :ok

  defp assert_tree_stable(_before, _after), do: {:error, :validation_tree_mutated}

  defp attach_binding_evidence(result, nil), do: result

  defp attach_binding_evidence(result, binding) when is_map(result) and is_map(binding) do
    result
    |> Map.put(:validated_tree_oid, binding.tree_oid)
    |> Map.put(:validated_head, binding.head)
  end

  defp absolute_deadline(timeout) when is_integer(timeout) and timeout > 0 do
    System.monotonic_time(:millisecond) + timeout
  end

  defp absolute_deadline(_), do: System.monotonic_time(:millisecond) + 120_000
end

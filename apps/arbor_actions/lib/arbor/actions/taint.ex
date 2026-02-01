defmodule Arbor.Actions.Taint do
  @moduledoc """
  Taint role checking for action parameters.

  This module provides utilities for checking whether action parameters comply
  with taint policies. Actions declare which of their parameters are control
  parameters (affecting execution flow) vs data parameters (just processed content)
  via a `taint_roles/0` callback.

  ## Usage

  Actions that want taint checking should implement `taint_roles/0`:

      defmodule MyAction do
        use Jido.Action, ...

        def taint_roles do
          %{
            path: :control,    # Path affects what file is accessed
            content: :data     # Content is just processed, doesn't affect flow
          }
        end
      end

  The dispatcher can then use this module to check params:

      case Arbor.Actions.Taint.check_params(MyAction, params, taint_context) do
        :ok -> # proceed with execution
        {:error, {:taint_blocked, param, level, role}} -> # block with error
      end

  ## Backward Compatibility

  Actions without `taint_roles/0` are treated as having all `:data` parameters,
  which means all taint levels are allowed. This ensures existing actions work
  unchanged.
  """

  alias Arbor.Signals.Taint

  @doc """
  Get taint roles for an action module.

  Calls `action_module.taint_roles/0` if defined, otherwise returns an empty map
  (meaning all parameters are treated as `:data`).

  ## Examples

      iex> Arbor.Actions.Taint.roles_for(Arbor.Actions.Shell.Execute)
      %{command: :control, cwd: :control, sandbox: :control, env: :data, timeout: :data}

      iex> Arbor.Actions.Taint.roles_for(SomeModuleWithoutTaintRoles)
      %{}
  """
  @spec roles_for(module()) :: %{atom() => Taint.role()}
  def roles_for(action_module) do
    Code.ensure_loaded(action_module)

    if function_exported?(action_module, :taint_roles, 0) do
      action_module.taint_roles()
    else
      %{}
    end
  end

  @doc """
  Check if action parameters comply with taint policy.

  For each parameter that has a `:control` role, verifies that the taint level
  from the context allows its use as a control parameter using
  `Arbor.Signals.Taint.can_use_as?/2`.

  ## Parameters

  - `action_module` - The action module to check roles for
  - `params` - The parameters being passed to the action
  - `taint_context` - Map with `:taint` key, or `nil` for no taint context

  ## Returns

  - `:ok` if all parameters comply with taint policy
  - `{:error, {:taint_blocked, param_name, taint_level, :control}}` if a control
    parameter would be used with a disallowed taint level

  ## Backward Compatibility

  - If `taint_context` is `nil` or doesn't have a `:taint` key, all params pass
  - If the action has no `taint_roles/0` callback, all params are `:data` and pass

  ## Examples

      # Trusted data can be used for anything
      iex> Arbor.Actions.Taint.check_params(
      ...>   Arbor.Actions.Shell.Execute,
      ...>   %{command: "ls"},
      ...>   %{taint: :trusted}
      ...> )
      :ok

      # Untrusted data is blocked for control params
      iex> Arbor.Actions.Taint.check_params(
      ...>   Arbor.Actions.Shell.Execute,
      ...>   %{command: "rm -rf /"},
      ...>   %{taint: :untrusted}
      ...> )
      {:error, {:taint_blocked, :command, :untrusted, :control}}

      # No taint context means no enforcement
      iex> Arbor.Actions.Taint.check_params(
      ...>   Arbor.Actions.Shell.Execute,
      ...>   %{command: "ls"},
      ...>   nil
      ...> )
      :ok
  """
  @spec check_params(module(), map(), map() | nil) ::
          :ok | {:error, {:taint_blocked, atom(), Taint.level(), Taint.role()}}
  def check_params(_action_module, _params, nil), do: :ok

  def check_params(action_module, params, taint_context) when is_map(taint_context) do
    taint_level = Map.get(taint_context, :taint)

    if is_nil(taint_level) do
      # No taint in context, all params pass
      :ok
    else
      roles = roles_for(action_module)
      check_params_with_roles(params, roles, taint_level)
    end
  end

  @doc """
  Check if a specific parameter value is allowed given its role and taint level.

  This is a lower-level function for checking individual parameters.

  ## Examples

      iex> Arbor.Actions.Taint.allowed?(:control, :trusted)
      true

      iex> Arbor.Actions.Taint.allowed?(:control, :untrusted)
      false

      iex> Arbor.Actions.Taint.allowed?(:data, :untrusted)
      true
  """
  @spec allowed?(Taint.role(), Taint.level()) :: boolean()
  def allowed?(role, taint_level) do
    Taint.can_use_as?(taint_level, role)
  end

  # Private helpers

  defp check_params_with_roles(params, roles, taint_level) do
    # Find the first control param that violates taint policy
    violation =
      Enum.find_value(params, fn {param_name, _value} ->
        role = Map.get(roles, param_name, :data)

        if role == :control and not Taint.can_use_as?(taint_level, :control) do
          {:taint_blocked, param_name, taint_level, :control}
        else
          nil
        end
      end)

    case violation do
      nil -> :ok
      blocked -> {:error, blocked}
    end
  end
end

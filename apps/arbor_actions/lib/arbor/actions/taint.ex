defmodule Arbor.Actions.Taint do
  @moduledoc """
  Taint role checking for action parameters.

  This module provides utilities for checking whether action parameters comply
  with taint policies. Actions declare which of their parameters are control
  parameters (affecting execution flow) vs data parameters (just processed content)
  via a `taint_roles/0` callback.

  ## Extended Taint Roles

  Actions can declare sanitization requirements on control parameters:

      defmodule MyAction do
        use Jido.Action, ...

        def taint_roles do
          %{
            command: {:control, requires: [:command_injection]},
            path: {:control, requires: [:path_traversal]},
            url: {:control, requires: [:ssrf]},
            content: :data
          }
        end
      end

  When a taint role includes `requires:`, the system checks that the
  corresponding sanitization bits are set on the taint struct before allowing
  execution. This means the data must have passed through the appropriate
  sanitizer before it can be used as a control parameter.

  ## Role Formats

  - `:data` — no restrictions (any taint level allowed)
  - `:control` — blocks untrusted/hostile taint levels (backward compatible)
  - `{:control, requires: [:sanitizer_name]}` — blocks untrusted/hostile AND
    requires specific sanitization bits to be set

  ## Backward Compatibility

  Actions without `taint_roles/0` are treated as having all `:data` parameters.
  The bare `:control` atom continues to work exactly as before — only the
  `{:control, requires: [...]}` tuple format adds sanitization checks.

  **Fail-closed on legacy taint**: When a role requires sanitizations but the
  taint context contains a bare atom (no bitmask), the check fails — there's no
  evidence that sanitization was applied. Legacy atom taint only passes for roles
  without `requires:` (bare `:control` or `:data`).
  """

  alias Arbor.Signals.Taint

  @type role :: :data | :control | {:control, keyword()}

  @doc """
  Get taint roles for an action module.

  Calls `action_module.taint_roles/0` if defined, otherwise returns an empty map
  (meaning all parameters are treated as `:data`).

  ## Examples

      iex> Arbor.Actions.Taint.roles_for(Arbor.Actions.Shell.Execute)
      %{command: {:control, requires: [:command_injection]}, cwd: {:control, requires: [:path_traversal]}, sandbox: :control, env: :data, timeout: :data}

      iex> Arbor.Actions.Taint.roles_for(SomeModuleWithoutTaintRoles)
      %{}
  """
  @spec roles_for(module()) :: %{atom() => role()}
  def roles_for(action_module) do
    Code.ensure_loaded(action_module)

    if function_exported?(action_module, :taint_roles, 0) do
      action_module.taint_roles()
    else
      %{}
    end
  end

  @doc """
  Get the provenance taint an action assigns to its OWN output.

  This is boundary/provenance tainting (taint-tracking-rebuild Phase 1): an
  action that ingests data from outside the trust boundary (web fetch/search,
  external messages, etc.) declares the provenance of what it returns via an
  optional `output_taint/0` callback. The orchestrator records this level on
  the node's output context keys so downstream nodes that consume them can be
  gated at control parameters.

  Returns the declared level (e.g. `:untrusted`) or `nil` when the action does
  not declare output provenance (most actions — their output inherits taint
  from their inputs, handled by propagation rather than ingress labeling).

  ## Examples

      iex> Arbor.Actions.Taint.output_taint_for(Arbor.Actions.Web.Browse)
      :untrusted

      iex> Arbor.Actions.Taint.output_taint_for(SomeActionWithoutProvenance)
      nil
  """
  @spec output_taint_for(module()) :: Taint.level() | nil
  def output_taint_for(action_module), do: output_taint_for(action_module, %{})

  @doc """
  Resolve output provenance, allowing a params-aware declaration.

  Prefers `output_taint/1` (so an action like a file read can decide provenance
  from its params — a foreign path is `:untrusted`, a workspace path is not),
  then falls back to the static `output_taint/0`, then `nil`.
  """
  @spec output_taint_for(module(), map()) :: Taint.level() | nil
  def output_taint_for(action_module, params) do
    Code.ensure_loaded(action_module)

    cond do
      function_exported?(action_module, :output_taint, 1) ->
        action_module.output_taint(params)

      function_exported?(action_module, :output_taint, 0) ->
        action_module.output_taint()

      true ->
        nil
    end
  end

  @doc """
  Provenance for content read from a filesystem path (taint-rebuild Phase 1).

  Foreign / shared / sensitive locations are `:untrusted`; everything else
  returns `nil` (no provenance asserted — we never silently label a read
  `:trusted`, which would launder it). Mirrors the orchestrator's
  `auto_classify_by_path` heuristic.
  """
  @spec path_provenance(term()) :: :untrusted | nil
  def path_provenance(path) when is_binary(path) do
    if String.contains?(path, [
         ".env",
         "credentials",
         "secret",
         "private_key",
         "/tmp/",
         "/var/",
         "/proc/",
         "/Downloads/",
         "/downloads/"
       ]) do
      :untrusted
    else
      nil
    end
  end

  def path_provenance(_), do: nil

  @doc """
  Check if action parameters comply with taint policy.

  For each parameter with a `:control` role, verifies that the taint level
  allows its use as a control parameter. For parameters with
  `{:control, requires: [...]}`, also verifies that the required sanitization
  bits are set on the taint struct.

  ## Taint Context

  The `taint_context` map can contain either:
  - `%{taint: :trusted}` — legacy atom level (sanitization requirements skipped)
  - `%{taint: %Taint{level: ..., sanitizations: ...}}` — full struct (all checks)

  ## Returns

  - `:ok` if all parameters comply
  - `{:error, {:taint_blocked, param, level, :control}}` — taint level too high
  - `{:error, {:missing_sanitization, param, missing}}` — required sanitization not applied

  ## Examples

      # Trusted data passes all checks
      iex> Arbor.Actions.Taint.check_params(
      ...>   Arbor.Actions.Shell.Execute,
      ...>   %{command: "ls"},
      ...>   %{taint: :trusted}
      ...> )
      :ok

      # Untrusted data blocked for control params
      iex> Arbor.Actions.Taint.check_params(
      ...>   Arbor.Actions.Shell.Execute,
      ...>   %{command: "ls"},
      ...>   %{taint: :untrusted}
      ...> )
      {:error, {:taint_blocked, :command, :untrusted, :control}}

      # Struct taint with required sanitization missing
      iex> taint = %Arbor.Contracts.Security.Taint{level: :trusted, sanitizations: 0}
      iex> Arbor.Actions.Taint.check_params(
      ...>   Arbor.Actions.Shell.Execute,
      ...>   %{command: "ls"},
      ...>   %{taint: taint}
      ...> )
      {:error, {:missing_sanitization, :command, [:command_injection]}}

      # No taint context means no enforcement
      iex> Arbor.Actions.Taint.check_params(
      ...>   Arbor.Actions.Shell.Execute,
      ...>   %{command: "ls"},
      ...>   nil
      ...> )
      :ok
  """
  @spec check_params(module(), map(), map() | nil) ::
          :ok
          | {:error, {:taint_blocked, atom(), atom(), :control}}
          | {:error, {:missing_sanitization, atom(), [atom()]}}
  def check_params(_action_module, _params, nil), do: :ok

  def check_params(action_module, params, taint_context) when is_map(taint_context) do
    taint = Map.get(taint_context, :taint)

    if is_nil(taint) do
      :ok
    else
      roles = roles_for(action_module)
      check_params_with_roles(params, roles, taint)
    end
  end

  @doc """
  Check if a specific parameter value is allowed given its role and taint level.

  ## Examples

      iex> Arbor.Actions.Taint.allowed?(:control, :trusted)
      true

      iex> Arbor.Actions.Taint.allowed?(:control, :untrusted)
      false

      iex> Arbor.Actions.Taint.allowed?(:data, :untrusted)
      true

      iex> Arbor.Actions.Taint.allowed?({:control, requires: [:xss]}, :trusted)
      true
  """
  @spec allowed?(role(), atom()) :: boolean()
  def allowed?(:data, _taint_level), do: true
  def allowed?(:control, taint_level), do: Taint.can_use_as?(taint_level, :control)

  def allowed?({:control, _opts}, taint_level),
    do: Taint.can_use_as?(taint_level, :control)

  @doc """
  Extract required sanitizations from a role specification.

  Returns the list of required sanitization names, or `[]` if none required.

  ## Examples

      iex> Arbor.Actions.Taint.required_sanitizations(:control)
      []

      iex> Arbor.Actions.Taint.required_sanitizations({:control, requires: [:xss, :sqli]})
      [:xss, :sqli]

      iex> Arbor.Actions.Taint.required_sanitizations(:data)
      []
  """
  @spec required_sanitizations(role()) :: [atom()]
  def required_sanitizations(:data), do: []
  def required_sanitizations(:control), do: []

  def required_sanitizations({:control, opts}) when is_list(opts) do
    Keyword.get(opts, :requires, [])
  end

  @doc """
  Check if a taint struct satisfies the sanitization requirements for a role.

  Returns `{:ok, []}` if all requirements met, or `{:error, missing}` with
  the list of missing sanitizations.

  When taint is a struct with a `sanitizations` field, checks the bitmask.
  When taint is a legacy atom (no bitmask), fails closed — requirements
  cannot be verified, so they are treated as unmet.

  ## Examples

      iex> role = {:control, requires: [:command_injection]}
      iex> Arbor.Actions.Taint.check_sanitizations(role, %Arbor.Contracts.Security.Taint{sanitizations: 4})
      {:ok, []}

      iex> role = {:control, requires: [:command_injection, :path_traversal]}
      iex> Arbor.Actions.Taint.check_sanitizations(role, %Arbor.Contracts.Security.Taint{sanitizations: 4})
      {:error, [:path_traversal]}
  """
  @spec check_sanitizations(role(), term()) :: {:ok, []} | {:error, [atom()]}
  def check_sanitizations(role, taint) do
    required = required_sanitizations(role)

    case required do
      [] ->
        {:ok, []}

      _ ->
        sanitizations = extract_sanitizations(taint)

        if is_nil(sanitizations) do
          # No bitmask means sanitization hasn't been tracked — fail closed.
          # The role requires specific sanitizations, but there's no evidence
          # they were applied. Passing legacy atom taint doesn't bypass requirements.
          {:error, required}
        else
          missing =
            Enum.filter(required, fn name ->
              not Taint.sanitized?(sanitizations, name)
            end)

          case missing do
            [] -> {:ok, []}
            _ -> {:error, missing}
          end
        end
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp check_params_with_roles(params, roles, taint) do
    taint_level = extract_level(taint)

    Enum.reduce_while(params, :ok, fn {param_name, _value}, :ok ->
      role = Map.get(roles, param_name, :data)

      # First check: taint level allows the role
      if is_control_role?(role) and not Taint.can_use_as?(taint_level, :control) do
        {:halt, {:error, {:taint_blocked, param_name, taint_level, :control}}}
      else
        # Second check: required sanitizations are present
        case check_sanitizations(role, taint) do
          {:ok, []} ->
            {:cont, :ok}

          {:error, missing} ->
            {:halt, {:error, {:missing_sanitization, param_name, missing}}}
        end
      end
    end)
  end

  defp is_control_role?(:control), do: true
  defp is_control_role?({:control, _}), do: true
  defp is_control_role?(_), do: false

  defp extract_level(%{level: level}), do: level
  defp extract_level(level) when is_atom(level), do: level
  defp extract_level(_), do: :untrusted

  defp extract_sanitizations(%{sanitizations: s}) when is_integer(s), do: s
  defp extract_sanitizations(_), do: nil
end

defmodule Arbor.Actions.Sandbox do
  @moduledoc """
  Sandbox operations as Jido actions.

  This module provides Jido-compatible actions for creating and destroying
  sandboxed execution environments. Actions wrap the `Arbor.Sandbox` facade
  and provide proper observability through signals.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Create` | Create a Docker sandbox environment |
  | `Destroy` | Destroy a sandbox environment |

  ## Examples

      # Create a sandbox
      {:ok, result} = Arbor.Actions.Sandbox.Create.run(
        %{agent_id: "agent_001", level: "limited"},
        %{}
      )
      result.sandbox_id  # => "sbx_abc123..."

      # Destroy a sandbox
      {:ok, result} = Arbor.Actions.Sandbox.Destroy.run(
        %{sandbox_id: "sbx_abc123..."},
        %{}
      )

  ## Authorization

  When using `Arbor.Actions.authorize_and_execute/4`, the capability URI
  is `arbor://actions/execute/sandbox.create` or `arbor://actions/execute/sandbox.destroy`.
  """

  defmodule Create do
    @moduledoc """
    Create a Docker sandbox environment.

    Wraps `Arbor.Sandbox.create/2` as a Jido action for consistent
    execution and LLM tool schema generation.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `agent_id` | string | yes | Agent ID the sandbox is created for |
    | `level` | string | no | Sandbox level: pure, limited, full, container (default: limited) |
    | `base_path` | string | no | Base path for filesystem sandbox |
    | `timeout` | integer | no | Sandbox timeout in seconds |

    ## Returns

    - `sandbox_id` - The unique sandbox identifier
    - `agent_id` - The agent ID the sandbox was created for
    - `level` - The sandbox level
    - `status` - Status of the sandbox (always "created")
    """

    use Jido.Action,
      name: "sandbox_create",
      description: "Create a Docker sandbox environment for an agent",
      category: "sandbox",
      tags: ["sandbox", "docker", "isolation", "create"],
      schema: [
        agent_id: [
          type: :string,
          required: true,
          doc: "Agent ID the sandbox is created for"
        ],
        level: [
          type: {:in, ["pure", "limited", "full", "container"]},
          default: "limited",
          doc: "Sandbox level determining isolation restrictions"
        ],
        base_path: [
          type: :string,
          doc: "Base path for filesystem sandbox"
        ],
        timeout: [
          type: :integer,
          doc: "Sandbox timeout in seconds"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Common.SafeAtom

    @allowed_levels [:pure, :limited, :full, :container]

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{agent_id: agent_id} = params, _context) do
      Actions.emit_started(__MODULE__, %{agent_id: agent_id})

      opts = build_opts(params)

      {:ok, sandbox} = Arbor.Sandbox.create(agent_id, opts)

      result = %{
        sandbox_id: sandbox.id,
        agent_id: sandbox.agent_id,
        level: sandbox.level,
        status: "created"
      }

      Actions.emit_completed(__MODULE__, %{
        sandbox_id: sandbox.id,
        agent_id: agent_id,
        level: sandbox.level
      })

      {:ok, result}
    rescue
      e ->
        reason = Exception.message(e)
        Actions.emit_failed(__MODULE__, reason)
        {:error, format_error(reason)}
    end

    defp build_opts(params) do
      []
      |> maybe_add(:level, normalize_level(params[:level]))
      |> maybe_add(:base_path, params[:base_path])
      |> maybe_add(:timeout, params[:timeout])
    end

    defp normalize_level(nil), do: nil

    defp normalize_level(level) when is_binary(level) do
      case SafeAtom.to_allowed(level, @allowed_levels) do
        {:ok, atom} -> atom
        {:error, _} -> nil
      end
    end

    defp normalize_level(level) when is_atom(level), do: level

    defp maybe_add(opts, _key, nil), do: opts
    defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

    defp format_error({:unauthorized, reason}), do: "Unauthorized: #{inspect(reason)}"
    defp format_error(reason), do: "Sandbox creation failed: #{inspect(reason)}"
  end

  defmodule Destroy do
    @moduledoc """
    Destroy a sandbox environment.

    Wraps `Arbor.Sandbox.destroy/1` as a Jido action for consistent
    execution and LLM tool schema generation.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `sandbox_id` | string | yes | The sandbox ID to destroy |

    ## Returns

    - `sandbox_id` - The destroyed sandbox ID
    - `status` - Status of the operation (always "destroyed")
    """

    use Jido.Action,
      name: "sandbox_destroy",
      description: "Destroy a sandbox environment",
      category: "sandbox",
      tags: ["sandbox", "docker", "cleanup", "destroy"],
      schema: [
        sandbox_id: [
          type: :string,
          required: true,
          doc: "The sandbox ID to destroy"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{sandbox_id: sandbox_id}, _context) do
      Actions.emit_started(__MODULE__, %{sandbox_id: sandbox_id})

      case Arbor.Sandbox.destroy(sandbox_id) do
        :ok ->
          result = %{
            sandbox_id: sandbox_id,
            status: "destroyed"
          }

          Actions.emit_completed(__MODULE__, result)
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    defp format_error(:not_found), do: "Sandbox not found"
    defp format_error({:unauthorized, reason}), do: "Unauthorized: #{inspect(reason)}"
    defp format_error(reason), do: "Sandbox destruction failed: #{inspect(reason)}"
  end
end

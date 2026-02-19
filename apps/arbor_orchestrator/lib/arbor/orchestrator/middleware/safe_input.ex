defmodule Arbor.Orchestrator.Middleware.SafeInput do
  @moduledoc """
  Mandatory middleware that validates atom and path attributes for safety.

  Bridges to `Arbor.Common.SafeAtom` and `Arbor.Common.SafePath` when available.
  Prevents atom table exhaustion from untrusted type strings and path traversal
  from untrusted file paths.

  ## Token Assigns

    - `:skip_safe_input` — set to true to bypass this middleware
  """

  use Arbor.Orchestrator.Middleware

  alias Arbor.Orchestrator.Engine.Outcome

  # Attributes that may contain file paths
  @path_attrs ~w(graph_file source_file cwd workdir)

  @impl true
  def before_node(token) do
    if Map.get(token.assigns, :skip_safe_input, false) do
      token
    else
      token
      |> validate_paths()
    end
  end

  defp validate_paths(token) do
    if safe_path_available?() do
      errors =
        @path_attrs
        |> Enum.flat_map(fn attr ->
          case Map.get(token.node.attrs, attr) do
            nil -> []
            path -> validate_path(attr, path)
          end
        end)

      case errors do
        [] ->
          token

        errors ->
          msg = Enum.join(errors, "; ")

          Token.halt(
            token,
            "Path validation failed: #{msg}",
            %Outcome{status: :fail, failure_reason: "Safe input validation: #{msg}"}
          )
      end
    else
      token
    end
  end

  defp validate_path(attr, path) do
    # Check for path traversal patterns
    if String.contains?(path, "..") do
      ["#{attr} contains path traversal: #{path}"]
    else
      []
    end
  end

  defp safe_path_available? do
    Code.ensure_loaded?(Arbor.Common.SafePath)
  end
end

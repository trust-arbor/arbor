defmodule Arbor.Actions.Github do
  @moduledoc """
  GitHub-specific operations as Jido actions, layered on the `gh` CLI.

  Distinct from `Arbor.Actions.Git` because these are hosting-platform
  concerns (pull requests, releases, issue management) — not core
  git-protocol operations. GitLab, Forgejo, and others get their own
  namespaces (e.g. `Arbor.Actions.Gitlab`) when added.

  Requires `gh` installed and authenticated. Actions return
  `{:error, reason}` rather than attempting to install or authenticate
  on the caller's behalf.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `PR` | Open a pull request |
  """

  defmodule PR do
    @moduledoc """
    Open a pull request via the `gh` CLI.

    Requires `Arbor.Actions.authorized_principal/2`. Direct `run/2` without
    the facade-issued envelope fails closed. The authorized path is
    `Arbor.Actions.authorize_and_execute/4`, then
    `Arbor.Shell.authorize_and_execute/3`. If that API cannot run `gh`,
    its error is returned — this surface never falls back to trusted-system
    `execute/2` or `execute_direct/3`.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to the Git repository |
    | `title` | string | yes | PR title |
    | `body` | string | no | PR body (markdown supported) |
    | `base` | string | no | Base branch (default: repository default) |
    | `draft` | boolean | no | Open as draft (default: false) |

    ## Returns

    - `path` — repository path
    - `url` — PR URL emitted by `gh`
    - `title` — PR title
    - `draft?` — whether the PR was opened as draft
    """

    use Jido.Action,
      name: "github_pr",
      description: "Open a GitHub pull request via the `gh` CLI",
      category: "github",
      tags: ["github", "pr", "vcs"],
      schema: [
        path: [type: :string, required: true, doc: "Path to the Git repository"],
        title: [type: :string, required: true, doc: "PR title"],
        body: [type: :string, doc: "PR body (markdown)"],
        base: [type: :string, doc: "Base branch"],
        draft: [type: :boolean, default: false, doc: "Open as draft"]
      ]

    alias Arbor.Actions
    alias Arbor.Common.ShellEscape

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        title: {:control, requires: [:command_injection]},
        body: {:control, requires: [:command_injection]},
        base: {:control, requires: [:command_injection]},
        draft: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path, title: title} = params, context) do
      with {:ok, principal_id} <- Actions.authorized_principal(context, __MODULE__) do
        Actions.emit_started(__MODULE__, %{path: path, title: title})

        args = build_args(params)

        case gh_command(principal_id, path, args) do
          {:ok, result} ->
            url = String.trim(result.stdout) |> extract_url()

            output = %{
              path: path,
              url: url,
              title: title,
              draft?: params[:draft] == true
            }

            Actions.emit_completed(__MODULE__, %{path: path, url: url})
            {:ok, output}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, format_error(reason)}
        end
      else
        {:error, reason} -> {:error, format_error(reason)}
      end
    end

    defp build_args(params) do
      args = ["pr", "create", "--title", params.title]
      args = if params[:body], do: args ++ ["--body", params[:body]], else: args ++ ["--body", ""]
      args = if params[:base], do: args ++ ["--base", params[:base]], else: args
      args = if params[:draft], do: args ++ ["--draft"], else: args
      args
    end

    defp gh_command(principal_id, path, args) do
      command =
        args
        |> Enum.map(&ShellEscape.escape_arg/1)
        |> then(&["gh" | &1])
        |> Enum.join(" ")

      # Never fall back to trusted-system execute/execute_direct.
      case Arbor.Shell.authorize_and_execute(principal_id, command,
             cwd: path,
             # gh can prompt for browser auth on long network ops
             timeout: 60_000
           ) do
        {:ok, %{exit_code: 0} = result} ->
          {:ok, result}

        {:ok, %{stderr: stderr, stdout: stdout}} ->
          error = if stderr != "", do: stderr, else: stdout
          {:error, String.trim(error)}

        {:ok, :pending_approval, proposal_id} ->
          {:error, {:pending_approval, proposal_id}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp format_error(:action_principal_authority_required),
      do: Actions.unauthorized_message(:action_principal_authority_required)

    defp format_error({:unauthorized, reason}), do: Actions.unauthorized_message(reason)
    defp format_error({:agent_executable_not_allowed, _} = reason),
      do: Actions.unauthorized_message(reason)

    defp format_error(reason) when is_binary(reason), do: "Failed to open PR: #{reason}"
    defp format_error(reason), do: Actions.unauthorized_message(reason)

    # `gh pr create` prints the URL on the last non-empty line. Extract it.
    defp extract_url(output) do
      output
      |> String.split("\n", trim: true)
      |> Enum.reverse()
      |> Enum.find(fn line -> String.starts_with?(line, "https://") end)
      |> case do
        nil -> output
        url -> url
      end
    end
  end
end

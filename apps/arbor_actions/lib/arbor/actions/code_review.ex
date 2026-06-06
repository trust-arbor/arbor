defmodule Arbor.Actions.CodeReview do
  @moduledoc """
  Actions for the code-review-with-fixes pipeline
  (`apps/arbor_scheduler/priv/pipelines/code_review_with_fixes.dot`).

  ## Actions

    - `apply_changes` — takes a JSON document describing per-file new
      content and writes the files to disk, scoped to a workdir.
  """

  defmodule ApplyChanges do
    @moduledoc """
    Apply a batch of file changes produced by an LLM-drafted fix step.

    Reads a JSON document with the shape

        {"changes": [{"file": "rel/path.ex", "content": "<full new content>"}]}

    and writes each entry to `<workdir>/<file>`. Path safety: relative
    paths only; `..` traversal rejected; absolute paths rejected. The
    safety checks live here, not in the writing action layer, because
    this action knows the workdir bound and can apply
    `Arbor.Common.SafePath.resolve_within/2` consistently.

    ## Returns

        {:ok, %{
          files_written: integer,
          paths: [String.t()]
        }}

    On any per-file failure, the action halts at that file and returns
    an error with the offending path. Earlier writes are NOT rolled back
    — fix iterations re-overwrite anyway, so partial state is recovered
    on the next round.
    """

    use Jido.Action,
      name: "apply_changes",
      description: "Apply a batch of LLM-drafted file changes within a workdir",
      category: "code_review",
      tags: ["code_review", "filesystem"],
      schema: [
        changes_json: [
          type: :string,
          required: true,
          doc: "JSON document with `{\"changes\": [{\"file\": ..., \"content\": ...}]}`"
        ],
        workdir: [
          type: :string,
          required: true,
          doc: "Absolute path bounding where files may be written"
        ]
      ]

    alias Arbor.Common.SafePath

    def taint_roles do
      %{
        changes_json: :data,
        workdir: :control
      }
    end

    @impl true
    def run(params, _context) do
      with {:ok, decoded} <- decode_changes(params.changes_json),
           {:ok, change_list} <- extract_changes_list(decoded),
           :ok <- ensure_workdir(params.workdir),
           {:ok, paths} <- write_each(change_list, params.workdir) do
        {:ok, %{files_written: length(paths), paths: paths}}
      end
    end

    defp decode_changes(json) do
      case Jason.decode(json) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, reason} -> {:error, {:invalid_changes_json, reason}}
      end
    end

    defp extract_changes_list(%{"changes" => list}) when is_list(list), do: {:ok, list}
    defp extract_changes_list(_), do: {:error, :changes_field_missing_or_not_a_list}

    defp ensure_workdir(workdir) do
      cond do
        not is_binary(workdir) -> {:error, {:invalid_workdir, workdir}}
        Path.type(workdir) != :absolute -> {:error, {:workdir_not_absolute, workdir}}
        not File.dir?(workdir) -> {:error, {:workdir_not_a_directory, workdir}}
        true -> :ok
      end
    end

    defp write_each(change_list, workdir) do
      Enum.reduce_while(change_list, {:ok, []}, fn change, {:ok, acc} ->
        case write_one(change, workdir) do
          {:ok, full_path} -> {:cont, {:ok, [full_path | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, paths} -> {:ok, Enum.reverse(paths)}
        err -> err
      end
    end

    defp write_one(%{"file" => rel_path, "content" => content}, workdir)
         when is_binary(rel_path) and is_binary(content) do
      case SafePath.resolve_within(rel_path, workdir) do
        {:ok, full_path} ->
          with :ok <- File.mkdir_p(Path.dirname(full_path)),
               :ok <- File.write(full_path, content) do
            {:ok, full_path}
          else
            {:error, reason} -> {:error, {:write_failed, rel_path, reason}}
          end

        {:error, reason} ->
          {:error, {:path_rejected, rel_path, reason}}
      end
    end

    defp write_one(other, _workdir), do: {:error, {:invalid_change_entry, other}}
  end
end

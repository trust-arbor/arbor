defmodule Arbor.Actions.Reports.BuildMorningDigest do
  @moduledoc """
  Consolidate the two reviewed local report topics for the current UTC date.

  Requires an authenticated action principal and an existing canonical workdir
  containing reports/upstream-deps, reports/upstream-deps-summary and
  reports/morning-digest directories. Every file operation uses the existing
  path-scoped authorization boundary. There are no shell, network or LLM calls.

  Reads are bounded to 256 KiB each. Publication uses a same-directory exclusive
  temporary file, file sync, and rename. Success acknowledges the rename; it does
  not promise directory-fsync durability or rollback after caller death.
  """

  use Jido.Action,
    name: "reports_build_morning_digest",
    description: "Build the current UTC day's digest from two local report topics",
    category: "reports",
    tags: ["reports", "digest", "pipeline_internal"],
    schema: [
      reports_directory: [type: :string, required: true],
      topics: [type: {:list, :string}, required: true]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Config
  alias Arbor.Actions.File, as: FileActions
  alias Arbor.Actions.Reports.DigestCore
  alias Arbor.Common.SafePath

  def requires_authenticated_principal?, do: true
  def effect_class, do: :local_write
  def taint_roles, do: %{reports_directory: :control, topics: :control}

  @impl true
  def run(params, context) do
    with {:ok, principal} <- Actions.authorized_principal(context, __MODULE__),
         :ok <- routine_entry(context, principal),
         {:ok, plan} <- DigestCore.new(params, Date.utc_today()),
         {:ok, workdir} <- canonical_workdir(context),
         {:ok, reports} <- read_reports(plan.inputs, workdir, context),
         {:ok, digest} <- DigestCore.render(plan, reports),
         {:ok, path} <- publish(plan.output, digest.content, workdir, context) do
      {:ok,
       %{
         path: path,
         date: plan.day,
         included_topics: digest.included,
         missing_topics: digest.missing,
         bytes_written: byte_size(digest.content)
       }}
    end
  end

  defp canonical_workdir(%{workdir: workdir}) when is_binary(workdir) do
    with true <- Path.type(workdir) == :absolute,
         {:ok, ^workdir} <- SafePath.resolve_real(workdir),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(workdir) do
      {:ok, workdir}
    else
      _ -> {:error, :canonical_workdir_required}
    end
  end

  defp canonical_workdir(_context), do: {:error, :canonical_workdir_required}

  defp read_reports(inputs, workdir, context) do
    Enum.reduce_while(inputs, {:ok, []}, fn {topic, relative}, {:ok, reports} ->
      with {:ok, path} <- authorized_path(relative, workdir, context, :read),
           {:ok, content} <- read_report(path) do
        {:cont, {:ok, reports ++ [{topic, content}]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp read_report(path) do
    case File.lstat(path) do
      {:error, :enoent} -> {:ok, :missing}
      {:ok, %File.Stat{type: :regular}} -> bounded_read(path)
      {:ok, _} -> {:error, :report_not_regular}
      {:error, reason} -> {:error, {:report_read_failed, reason}}
    end
  end

  defp bounded_read(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, DigestCore.file_limit() + 1) do
            :eof -> {:ok, ""}
            content when is_binary(content) -> admit_read(content)
            {:error, reason} -> {:error, {:report_read_failed, reason}}
          end
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, {:report_read_failed, reason}}
    end
  end

  defp admit_read(content) do
    if byte_size(content) <= DigestCore.file_limit(),
      do: {:ok, content},
      else: {:error, :report_too_large}
  end

  defp publish(relative, content, workdir, context) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    temporary = Path.join(Path.dirname(relative), ".arbor-digest-#{suffix}.tmp")

    with {:ok, path} <- authorized_path(relative, workdir, context, :write),
         {:ok, temporary_path} <- authorized_path(temporary, workdir, context, :write) do
      publish_temporary(temporary_path, path, relative, content, workdir, context)
    end
  end

  defp publish_temporary(temporary, path, relative, content, workdir, context) do
    case File.open(temporary, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        try do
          with :ok <- IO.binwrite(file, content),
               :ok <- :file.sync(file),
               {:ok, ^path} <- authorized_path(relative, workdir, context, :write),
               :ok <- File.rename(temporary, path) do
            {:ok, path}
          else
            {:error, reason} -> {:error, {:digest_write_failed, reason}}
          end
        after
          File.close(file)
          File.rm(temporary)
        end

      {:error, reason} ->
        {:error, {:digest_write_failed, reason}}
    end
  end

  defp authorized_path(relative, workdir, context, operation) do
    with {:ok, path} <- SafePath.resolve_within(relative, workdir),
         :ok <- canonical_parent(path, workdir),
         :ok <- regular_or_absent(path),
         {:ok, ^path} <- FileActions.authorize_file_op(context, path, operation),
         :ok <-
           routine_effect(context, %{
             principal: context.agent_id,
             operation: operation,
             path: path
           }) do
      {:ok, path}
    else
      {:ok, _other_path} -> {:error, :report_path_changed}
      {:error, _} = error -> error
    end
  end

  defp routine_entry(context, principal) do
    scheduler = Config.scheduler_module()

    with {:ok, required?} <- scheduler.routine_effect_requirement(principal) do
      case {required?, Map.fetch(context, :routine_effect_token)} do
        {true, :error} ->
          {:error, :routine_effect_token_required}

        {false, :error} ->
          :ok

        {_, {:ok, token}} ->
          scheduler.authorize_routine_effect(token, %{principal: principal, operation: :enter})
      end
    end
  end

  defp routine_effect(context, effect) do
    case Map.fetch(context, :routine_effect_token) do
      :error ->
        :ok

      {:ok, token} ->
        Config.scheduler_module().authorize_routine_effect(token, effect)
    end
  end

  defp canonical_parent(path, workdir) do
    parent = Path.dirname(path)

    with {:ok, ^workdir} <- SafePath.resolve_real(workdir),
         {:ok, ^parent} <- SafePath.resolve_real(parent),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(parent) do
      :ok
    else
      _ -> {:error, :report_directory_not_canonical}
    end
  end

  defp regular_or_absent(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, :report_not_regular}
      {:error, reason} -> {:error, {:report_stat_failed, reason}}
    end
  end
end

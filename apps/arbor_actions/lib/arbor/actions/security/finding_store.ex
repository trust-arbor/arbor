defmodule Arbor.Actions.Security.FindingStore do
  @moduledoc """
  File-backed store for Security Sentinel findings, with status lifecycle.

  Each finding is one markdown file (`<dir>/<id>.md`) whose YAML frontmatter
  (`status:`) is the source of truth. The file name is the finding's stable
  `dedup_key`, so re-detection maps to the same file — which lets the store make
  a **status-aware** decision instead of blindly overwriting:

    * unseen        → write as `:open`            → `{:recorded, finding}`
    * triaged out   (`:wontfix` / `:false_positive` / `:accepted`)
                    → leave untouched              → `{:suppressed, status}`
    * previously `:fixed` but detected again
                    → rewrite as `:regressed`      → `{:reopened, finding}`
    * otherwise (`:open` / `:triaged` / `:in_remediation` / `:regressed`)
                    → refresh, keep status         → `{:updated, finding}`

  This is why a finding a human marked `wontfix` does not reappear on the next
  scan, and a `fixed` finding that comes back is surfaced as a regression.

  Design note: file-backed (not BufferedStore-backed) so it works identically
  whether the scan runs in-app (agent/pipeline) or via the `--no-start`
  `mix arbor.security.scan` task, with no supervision/hierarchy wiring. A
  BufferedStore backend is a future swap-in for dashboard/cluster queryability.
  """

  alias Arbor.Contracts.Security.Finding

  @default_dir ".arbor/security/findings"

  # Statuses that mean "a human has decided" — re-detection must not disturb them.
  @suppressing_statuses [:wontfix, :false_positive, :accepted]

  @type record_outcome ::
          {:recorded, Finding.t()}
          | {:updated, Finding.t()}
          | {:reopened, Finding.t()}
          | {:suppressed, Finding.status()}

  @doc "Returns the store directory (override with the `:dir` opt elsewhere)."
  @spec default_dir() :: String.t()
  def default_dir, do: @default_dir

  @doc """
  Status-aware record of a freshly-detected finding. See the module doc for the
  decision table. Writes the markdown file unless the existing finding is
  suppressed.
  """
  @spec record(Finding.t(), String.t()) :: record_outcome()
  def record(%Finding{} = finding, dir \\ @default_dir) do
    case current_status(finding.id, dir) do
      nil ->
        write(%{finding | status: :open}, dir)
        {:recorded, %{finding | status: :open}}

      status when status in @suppressing_statuses ->
        {:suppressed, status}

      :fixed ->
        reopened = %{finding | status: :regressed}
        write(reopened, dir)
        {:reopened, reopened}

      status ->
        kept = %{finding | status: status}
        write(kept, dir)
        {:updated, kept}
    end
  end

  @doc "Reads a finding's full markdown content by id."
  @spec read(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def read(id, dir \\ @default_dir), do: read_existing(path_for(id, dir))

  @doc "Reads the persisted status of a finding by id, or `nil` if not present."
  @spec current_status(String.t(), String.t()) :: Finding.status() | nil
  def current_status(id, dir \\ @default_dir) do
    case File.read(path_for(id, dir)) do
      {:ok, content} -> Finding.status_from_markdown(content)
      {:error, _} -> nil
    end
  end

  @doc """
  Sets a finding's status in place (triage). Optionally appends a note.

  Returns `:ok`, `{:error, :not_found}`, or `{:error, reason}` from the markdown
  rewrite. This is the human/agent feedback channel — `:false_positive` here
  feeds detector tuning.
  """
  @spec set_status(String.t(), Finding.status(), keyword()) :: :ok | {:error, term()}
  def set_status(id, status, opts \\ []) do
    dir = Keyword.get(opts, :dir, @default_dir)
    note = Keyword.get(opts, :note)
    path = path_for(id, dir)

    with {:ok, content} <- read_existing(path),
         {:ok, updated} <- Finding.replace_status_in_markdown(content, status) do
      File.write!(path, maybe_append_note(updated, status, note))
      :ok
    end
  end

  @doc """
  Appends an adversarial-verification verdict to a finding's file (advisory — it
  annotates, it does not change status). Returns `:ok` or `{:error, :not_found}`.
  """
  @spec annotate_verification(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def annotate_verification(id, verdict, opts \\ []) do
    dir = Keyword.get(opts, :dir, @default_dir)
    path = path_for(id, dir)

    with {:ok, content} <- read_existing(path) do
      File.write!(path, content <> verification_block(verdict))
      :ok
    end
  end

  defp verification_block(v) do
    dissent =
      case Map.get(v, :dissent, []) do
        [] -> "  (none)"
        reasons -> Enum.map_join(reasons, "\n", &"  - #{&1}")
      end

    """

    ## Verification (adversarial)
    - verdict: #{v.verdict} (#{v.refuted}/#{v.total} skeptics refuted)
    - confidence: #{v.confidence}
    - dissent:
    #{dissent}
    """
  end

  @doc """
  Lists finding ids in the store, optionally filtered by status.

  Returns `[{id, status}]`.
  """
  @spec list(keyword()) :: [{String.t(), Finding.status() | nil}]
  def list(opts \\ []) do
    dir = Keyword.get(opts, :dir, @default_dir)
    only = Keyword.get(opts, :status)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(fn file ->
          id = String.replace_suffix(file, ".md", "")
          {id, current_status(id, dir)}
        end)
        |> filter_status(only)

      {:error, _} ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp filter_status(entries, nil), do: entries
  defp filter_status(entries, status), do: Enum.filter(entries, fn {_id, s} -> s == status end)

  defp write(%Finding{} = finding, dir) do
    File.mkdir_p!(dir)
    File.write!(path_for(finding.id, dir), Finding.to_markdown(finding))
  end

  defp read_existing(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_append_note(content, _status, nil), do: content

  defp maybe_append_note(content, status, note) do
    content <> "\n> triage → #{status}: #{note}\n"
  end

  defp path_for(id, dir), do: Path.join(dir, id <> ".md")
end

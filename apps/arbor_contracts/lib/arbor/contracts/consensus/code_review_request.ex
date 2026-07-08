defmodule Arbor.Contracts.Consensus.CodeReviewRequest do
  @moduledoc """
  Input contract for code-review council pipelines.

  The review loop hands a completed coding-agent branch to a council as a
  JSON-clean payload: the branch diff, the touched files, the branch/base refs,
  the agent intent, and the originating agent id. This struct is the typed
  boundary before that payload enters a DOT pipeline.
  """

  use TypedStruct

  typedstruct enforce: true do
    @typedoc "A code-review request for a completed coding-agent branch"

    field(:diff, String.t())
    field(:files, [String.t()])
    field(:branch, String.t())
    field(:base_ref, String.t() | nil, enforce: false, default: nil)
    field(:intent, String.t(), enforce: false, default: "")
    field(:agent_id, String.t() | nil, enforce: false, default: nil)
  end

  @doc """
  Build a review request from atom-keyed, string-keyed, or keyword attrs.

  Required fields:

    * `:diff` - a non-empty git diff
    * `:files` - a non-empty list of touched file paths
    * `:branch` - the review branch name
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    attrs
    |> Map.new()
    |> new()
  end

  def new(attrs) when is_map(attrs) do
    with {:ok, diff} <- required_string(attrs, :diff),
         {:ok, files} <- required_files(attrs),
         {:ok, branch} <- required_string(attrs, :branch),
         {:ok, base_ref} <- optional_string(attrs, :base_ref, nil),
         {:ok, intent} <- optional_string(attrs, :intent, ""),
         {:ok, agent_id} <- optional_string(attrs, :agent_id, nil) do
      {:ok,
       %__MODULE__{
         diff: diff,
         files: files,
         branch: branch,
         base_ref: base_ref,
         intent: intent,
         agent_id: agent_id
       }}
    end
  end

  @doc """
  Convert the request to Engine context values.

  The returned map is JSON-clean and intentionally includes both flat keys
  (`diff` / `review.diff`) and a nested `review.request` map. Flat keys are
  convenient for `context_keys` and debugging; the nested map is convenient for
  future handlers that want the request as one value. `review.prompt` is the
  string fed to LLM reviewer nodes through `prompt_context_key`.
  """
  @spec to_context(t()) :: map()
  def to_context(%__MODULE__{} = request) do
    request_map = %{
      "diff" => request.diff,
      "files" => request.files,
      "branch" => request.branch,
      "base_ref" => request.base_ref,
      "intent" => request.intent,
      "agent_id" => request.agent_id
    }

    question = "Should branch #{request.branch} be accepted for human review?"

    %{
      "review.request" => request_map,
      "diff" => request.diff,
      "files" => request.files,
      "branch" => request.branch,
      "base_ref" => request.base_ref,
      "intent" => request.intent,
      "agent_id" => request.agent_id,
      "review.diff" => request.diff,
      "review.files" => request.files,
      "review.branch" => request.branch,
      "review.base_ref" => request.base_ref,
      "review.intent" => request.intent,
      "review.agent_id" => request.agent_id,
      "review.prompt" => prompt_text(request),
      "council.question" => question
    }
  end

  @doc """
  Render a stable prompt body for the reviewer LLM nodes.
  """
  @spec prompt_text(t()) :: String.t()
  def prompt_text(%__MODULE__{} = request) do
    """
    Branch: #{request.branch}
    Base ref: #{request.base_ref || "unknown"}
    Agent id: #{request.agent_id || "unknown"}

    Intent:
    #{blank_to_none(request.intent)}

    Files:
    #{format_files(request.files)}

    Diff:
    ```diff
    #{request.diff}
    ```
    """
    |> String.trim()
  end

  defp required_string(attrs, key) do
    with {:ok, value} <- fetch_attr(attrs, key),
         :ok <- validate_non_empty_string(key, value) do
      {:ok, value}
    end
  end

  defp optional_string(attrs, key, default) do
    case fetch_attr(attrs, key) do
      {:ok, nil} ->
        {:ok, default}

      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, value} ->
        {:error, {:invalid_field, key, {:expected_string_or_nil, value}}}

      {:error, {:missing_required_field, ^key}} ->
        {:ok, default}
    end
  end

  defp required_files(attrs) do
    with {:ok, files} <- fetch_attr(attrs, :files),
         :ok <- validate_files(files) do
      {:ok, files}
    end
  end

  defp fetch_attr(attrs, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> {:ok, Map.get(attrs, key)}
      Map.has_key?(attrs, string_key) -> {:ok, Map.get(attrs, string_key)}
      true -> {:error, {:missing_required_field, key}}
    end
  end

  defp validate_non_empty_string(key, value)
       when is_binary(value) do
    if String.trim(value) == "" do
      {:error, {:invalid_field, key, :empty}}
    else
      :ok
    end
  end

  defp validate_non_empty_string(key, value),
    do: {:error, {:invalid_field, key, {:expected_string, value}}}

  defp validate_files(files) when is_list(files) and files != [] do
    case Enum.find(files, fn file -> not valid_file?(file) end) do
      nil -> :ok
      invalid -> {:error, {:invalid_field, :files, {:invalid_path, invalid}}}
    end
  end

  defp validate_files([]), do: {:error, {:invalid_field, :files, :empty}}
  defp validate_files(value), do: {:error, {:invalid_field, :files, {:expected_list, value}}}

  defp valid_file?(file) when is_binary(file), do: String.trim(file) != ""
  defp valid_file?(_), do: false

  defp blank_to_none(value) when is_binary(value) do
    if String.trim(value) == "", do: "none provided", else: value
  end

  defp format_files(files), do: Enum.map_join(files, "\n", &"- #{&1}")
end

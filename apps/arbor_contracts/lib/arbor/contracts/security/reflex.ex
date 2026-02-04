defmodule Arbor.Contracts.Security.Reflex do
  @moduledoc """
  Safety check definition for instant blocking before authorization.

  Reflexes are the fastest safety layer — pattern-based checks that fire
  before capability authorization. They catch obviously dangerous patterns
  immediately, without the overhead of permission lookups.

  ## Reflex Types

  - `:pattern` - Regex pattern match against command/input
  - `:action` - Block specific action atoms
  - `:path` - Glob pattern match against file paths
  - `:custom` - Custom function check

  ## Response Types

  - `:block` - Prevent the action entirely
  - `:warn` - Allow but emit warning signal
  - `:log` - Allow but log for audit

  ## Priority

  Higher priority reflexes are checked first. Built-in safety reflexes
  (like rm -rf blocking) should have priority 100.

  ## Example

      %Reflex{
        id: "reflex_rm_rf",
        name: "Block rm -rf",
        type: :pattern,
        trigger: {:pattern, ~r/rm\\s+(-[rf]+\\s+)*[\\/~]/},
        response: :block,
        message: "Blocked: recursive delete of root or home",
        priority: 100
      }
  """

  use TypedStruct

  @typedoc "Type of reflex trigger"
  @type reflex_type :: :pattern | :action | :path | :custom

  @typedoc """
  Trigger condition for the reflex.

  - `{:pattern, regex}` - Match against command string
  - `{:action, atom}` - Match against action name
  - `{:path, glob}` - Match against file path (glob pattern)
  - `{:custom, fun}` - Custom function `(map() -> boolean())`
  """
  @type trigger ::
          {:pattern, Regex.t()}
          | {:action, atom()}
          | {:path, String.t()}
          | {:custom, (map() -> boolean())}

  @typedoc "Response when reflex triggers"
  @type response :: :block | :warn | :log

  typedstruct do
    @typedoc "A reflex safety check definition"

    field :id, String.t(), enforce: true
    field :name, String.t(), enforce: true
    field :type, reflex_type(), enforce: true
    field :trigger, trigger(), enforce: true
    field :response, response(), default: :block
    field :message, String.t() | nil, default: nil
    field :enabled, boolean(), default: true
    field :priority, integer(), default: 50
  end

  @doc """
  Creates a new Reflex.
  """
  @spec new(String.t(), reflex_type(), trigger(), keyword()) :: t()
  def new(name, type, trigger, opts \\ []) do
    %__MODULE__{
      id: opts[:id] || generate_id(),
      name: name,
      type: type,
      trigger: trigger,
      response: opts[:response] || :block,
      message: opts[:message],
      enabled: Keyword.get(opts, :enabled, true),
      priority: opts[:priority] || 50
    }
  end

  @doc """
  Creates a pattern-based reflex.
  """
  @spec pattern(String.t(), Regex.t(), keyword()) :: t()
  def pattern(name, regex, opts \\ []) do
    new(name, :pattern, {:pattern, regex}, opts)
  end

  @doc """
  Creates an action-blocking reflex.
  """
  @spec action(String.t(), atom(), keyword()) :: t()
  def action(name, action_atom, opts \\ []) do
    new(name, :action, {:action, action_atom}, opts)
  end

  @doc """
  Creates a path-blocking reflex.
  """
  @spec path(String.t(), String.t(), keyword()) :: t()
  def path(name, glob_pattern, opts \\ []) do
    new(name, :path, {:path, glob_pattern}, opts)
  end

  @doc """
  Creates a custom reflex with a checker function.
  """
  @spec custom(String.t(), (map() -> boolean()), keyword()) :: t()
  def custom(name, check_fn, opts \\ []) when is_function(check_fn, 1) do
    new(name, :custom, {:custom, check_fn}, opts)
  end

  @doc """
  Checks if the reflex matches the given context.
  """
  @spec matches?(t(), map()) :: boolean()
  def matches?(%__MODULE__{enabled: false}, _context), do: false

  def matches?(%__MODULE__{trigger: {:pattern, regex}}, %{command: command})
      when is_binary(command) do
    Regex.match?(regex, command)
  end

  def matches?(%__MODULE__{trigger: {:action, action_atom}}, %{action: action})
      when is_atom(action) do
    action == action_atom
  end

  def matches?(%__MODULE__{trigger: {:path, glob}}, %{path: path}) when is_binary(path) do
    # Simple glob matching - could be enhanced with PathGlob library
    pattern = glob_to_regex(glob)
    Regex.match?(pattern, path)
  end

  def matches?(%__MODULE__{trigger: {:custom, check_fn}}, context) do
    check_fn.(context)
  end

  def matches?(%__MODULE__{}, _context), do: false

  @doc """
  Enables the reflex.
  """
  @spec enable(t()) :: t()
  def enable(%__MODULE__{} = reflex), do: %{reflex | enabled: true}

  @doc """
  Disables the reflex.
  """
  @spec disable(t()) :: t()
  def disable(%__MODULE__{} = reflex), do: %{reflex | enabled: false}

  # Convert simple glob pattern to regex
  # Glob patterns come from trusted reflex definitions, not user input.
  # The Regex.escape/1 call sanitizes any regex metacharacters, making ReDoS
  # attacks infeasible — the resulting pattern has linear complexity.
  defp glob_to_regex(glob) do
    pattern =
      glob
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", ".")

    # credo:disable-for-next-line Credo.Check.Security.UnsafeRegexCompile
    Regex.compile!("^" <> pattern <> "$")
  end

  defp generate_id do
    "rfx_" <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
  end
end

# Note: Jason.Encoder for Reflex is complex because trigger can contain
# a Regex or function. For now, we'll encode what we can.
defimpl Jason.Encoder, for: Arbor.Contracts.Security.Reflex do
  def encode(reflex, opts) do
    reflex
    |> Map.from_struct()
    |> Map.update(:trigger, nil, &encode_trigger/1)
    |> Jason.Encode.map(opts)
  end

  defp encode_trigger({:pattern, %Regex{} = regex}), do: %{type: "pattern", value: Regex.source(regex)}
  defp encode_trigger({:action, atom}), do: %{type: "action", value: Atom.to_string(atom)}
  defp encode_trigger({:path, glob}), do: %{type: "path", value: glob}
  defp encode_trigger({:custom, _fun}), do: %{type: "custom", value: "<function>"}
end

defmodule Arbor.Gateway.MCP.ToolFingerprintCore do
  @moduledoc """
  Pure pin-and-diff of MCP tool definitions (SEAL-class description
  poisoning and rug-pulls, arXiv:2610.25372).

  ## First-discovery policy

  A tool name that has never been pinned is auto-admitted and pinned.
  That matches `ClientConnection` on 2026-10-20: first `tools/list` after
  connect is cached with no extra operator prompt. Server-connect approval
  (`Arbor.Security.mcp_server_approval_uri/2`) still gates starting the
  connection; tool-call capabilities still gate `call_tool`. This core only
  pins what the model would see (`name`, `description`, `inputSchema`).

  ## Refresh / list_changed

  Later lists (`refresh_tools/1` or `notifications/tools/list_changed`) hash
  each tool and compare it to the pin. A mismatch quarantines that tool —
  it is excluded from the presented list — until `approve/2` re-pins the
  observed definition. Unchanged names stay admitted. Pins for names missing
  from the latest list are kept so a later reuse of the name with a new
  description is still gated.

  A rename is a new name and follows first-discovery. There is no stable
  MCP tool id other than `name`.
  """

  @type tool :: map()
  @type pin_map :: %{optional(String.t()) => String.t()}
  @type change :: %{name: String.t(), pinned_hash: String.t(), observed_hash: String.t()}
  @type effect :: {:emit, atom(), map()}
  @type decision :: %{
          admitted: [tool()],
          quarantined: [tool()],
          pins: pin_map(),
          changes: [change()],
          effects: [effect()]
        }

  @doc """
  SHA-256 (lowercase hex) of the canonical `{name, description, inputSchema}`
  encoding. Atom and string keys/values that represent the same JSON term
  hash the same way.
  """
  @spec fingerprint(tool()) :: String.t()
  def fingerprint(tool) when is_map(tool) do
    tool
    |> canonical_term()
    |> then(&:erlang.term_to_binary(&1, [:deterministic]))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Canonical term hashed by `fingerprint/1`. Exposed for tests."
  @spec canonical_term(tool()) :: [{String.t(), term()}]
  def canonical_term(tool) when is_map(tool) do
    [
      {"description", canonicalize(field(tool, "description", ""))},
      {"inputSchema", canonicalize(field(tool, "inputSchema", %{}))},
      {"name", canonicalize(field(tool, "name", ""))}
    ]
  end

  @doc """
  Admit a discovered tool list against existing pins.

  Returns admitted tools (safe to present), quarantined tools (observed
  definitions held back), the updated pin map, and emit-effects for any
  rug-pull.
  """
  @spec admit(pin_map(), [tool()]) :: decision()
  def admit(pins, tools) when is_map(pins) and is_list(tools) do
    {admitted, quarantined, pins, changes} =
      Enum.reduce(tools, {[], [], pins, []}, &admit_one/2)

    changes = Enum.reverse(changes)
    quarantined = Enum.reverse(quarantined)

    %{
      admitted: Enum.reverse(admitted),
      quarantined: quarantined,
      pins: pins,
      changes: changes,
      effects: change_effects(changes)
    }
  end

  @doc """
  Re-pin an observed (usually quarantined) tool definition. This is the
  re-approval hook: the operator accepts the new text/schema.
  """
  @spec approve(pin_map(), tool()) ::
          {:ok, %{pins: pin_map(), tool: tool(), effects: [effect()]}}
          | {:error, :invalid_tool}
  def approve(pins, tool) when is_map(pins) and is_map(tool) do
    case tool_name(tool) do
      {:ok, name} ->
        hash = fingerprint(tool)

        {:ok,
         %{
           pins: Map.put(pins, name, hash),
           tool: tool,
           effects: [
             {:emit, :mcp_tool_fingerprint_approved,
              %{tool_name: name, fingerprint: hash, reason: :reapproved}}
           ]
         }}

      :error ->
        {:error, :invalid_tool}
    end
  end

  defp admit_one(tool, {admitted, quarantined, pins, changes}) do
    case tool_name(tool) do
      {:ok, name} ->
        hash = fingerprint(tool)

        case Map.fetch(pins, name) do
          :error ->
            {[tool | admitted], quarantined, Map.put(pins, name, hash), changes}

          {:ok, ^hash} ->
            {[tool | admitted], quarantined, pins, changes}

          {:ok, pinned} ->
            change = %{name: name, pinned_hash: pinned, observed_hash: hash}

            {admitted, [tool | quarantined], pins, [change | changes]}
        end

      :error ->
        {admitted, [tool | quarantined], pins, changes}
    end
  end

  defp change_effects([]), do: []

  defp change_effects(changes) do
    [
      {:emit, :mcp_tool_fingerprint_changed,
       %{
         tools: changes,
         quarantined_names: Enum.map(changes, & &1.name),
         reason: :fingerprint_mismatch
       }}
    ]
  end

  defp tool_name(tool) do
    case field(tool, "name", nil) do
      name when is_binary(name) and name != "" -> {:ok, name}
      _other -> :error
    end
  end

  defp field(tool, "name", default), do: Map.get(tool, :name) || Map.get(tool, "name", default)

  defp field(tool, "description", default),
    do: Map.get(tool, :description) || Map.get(tool, "description", default)

  defp field(tool, "inputSchema", default),
    do: Map.get(tool, :inputSchema) || Map.get(tool, "inputSchema", default)

  defp canonicalize(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {stringify_key(key), canonicalize(value)} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {key, values} -> {key, merge_canonical(values)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)

  defp canonicalize(atom) when is_atom(atom) and atom not in [true, false, nil],
    do: Atom.to_string(atom)

  defp canonicalize(other), do: other

  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key), do: inspect(key)

  defp merge_canonical([value]), do: value

  defp merge_canonical(values) do
    case Enum.uniq(values) do
      [one] -> one
      many -> Enum.sort_by(many, &inspect/1)
    end
  end
end

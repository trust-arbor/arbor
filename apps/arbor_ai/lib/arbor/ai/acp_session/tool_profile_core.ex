defmodule Arbor.AI.AcpSession.ToolProfileCore do
  @moduledoc """
  Pure derivation of an ACP agent's tool profile from the capabilities it
  already holds and its trust policy.

  The profile is what the ACP adapter should tell the CLI at launch
  (`allowed_tools` / everything-else-disallowed) so the agent never proposes a
  tool that Arbor would deny anyway. The per-call permission handler
  (`Arbor.AI.AcpSession.Handler`) stays in place as defense in depth; this
  core only removes the round trip — and, for agents with no tool grants at
  all, the CLI's attempt.

  Inputs are plain data: capability resource URIs (strings) and a function
  from a tool URI to the trust confirmation mode (`:auto | :gated | :deny`).
  No security or trust module is touched here.

  Tool identity follows the handler: a tool named `Read` is
  `arbor://acp/tool/Read`. A capability on `arbor://acp/tool` or
  `arbor://acp/tool/**` (or a longer exact prefix) is a wildcard: the CLI
  may offer every tool, and per-call authorization decides.
  """

  @tool_prefix "arbor://acp/tool"
  @tool_name_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._~-]*\z/

  @type mode :: :auto | :gated | :deny
  @type mode_fun :: (String.t() -> mode() | term())

  @type profile :: %{
          allowed_tools: [String.t()],
          gated_tools: [String.t()],
          wildcard?: boolean(),
          deny_unlisted?: boolean()
        }

  @doc """
  Derive the profile.

  - `capability_uris` — resource URIs of the capabilities the agent holds.
  - `mode_fun` — trust confirmation mode for a tool URI. Anything other than
    `:auto`/`:gated` is treated as deny (fail closed).

  Returns exact tool names sorted and de-duplicated. `allowed_tools` are the
  tools the CLI may run without asking; `gated_tools` are held tools that
  still need a human; `wildcard?` means a prefix capability covers the whole
  tool namespace (no CLI-level restriction possible); `deny_unlisted?` is
  `true` unless a wildcard is held.
  """
  @spec derive([String.t()], mode_fun()) :: profile()
  def derive(capability_uris, mode_fun)
      when is_list(capability_uris) and is_function(mode_fun, 1) do
    {names, wildcard?} =
      Enum.reduce(capability_uris, {[], false}, fn uri, {names, wildcard?} ->
        case classify(uri) do
          {:tool, name} -> {[name | names], wildcard?}
          :wildcard -> {names, true}
          :other -> {names, wildcard?}
        end
      end)

    names = names |> Enum.uniq() |> Enum.sort()

    {allowed, gated} =
      Enum.reduce(names, {[], []}, fn name, {allowed, gated} ->
        case safe_mode(mode_fun, "#{@tool_prefix}/#{name}") do
          :auto -> {[name | allowed], gated}
          :gated -> {allowed, [name | gated]}
          _deny -> {allowed, gated}
        end
      end)

    %{
      allowed_tools: Enum.reverse(allowed),
      gated_tools: Enum.reverse(gated),
      wildcard?: wildcard?,
      deny_unlisted?: not wildcard?
    }
  end

  def derive(_capability_uris, _mode_fun),
    do: %{allowed_tools: [], gated_tools: [], wildcard?: false, deny_unlisted?: true}

  @doc """
  Adapter-facing keyword options for the profile. Adapters that understand
  them restrict the CLI at launch; adapters that do not simply ignore them.
  Nothing is emitted for a wildcard profile (the CLI may offer every tool).
  """
  @spec adapter_opts(profile()) :: keyword()
  def adapter_opts(%{wildcard?: true}), do: []

  def adapter_opts(%{allowed_tools: allowed, gated_tools: gated}) do
    [allowed_tools: allowed, askable_tools: gated, deny_unlisted_tools: true]
  end

  def adapter_opts(_), do: [allowed_tools: [], askable_tools: [], deny_unlisted_tools: true]

  # -- private ------------------------------------------------------------------

  defp classify(uri) when is_binary(uri) do
    cond do
      uri == @tool_prefix or uri == @tool_prefix <> "/" or uri == @tool_prefix <> "/**" ->
        :wildcard

      String.starts_with?(uri, @tool_prefix <> "/") ->
        rest =
          binary_part(
            uri,
            byte_size(@tool_prefix) + 1,
            byte_size(uri) - byte_size(@tool_prefix) - 1
          )

        cond do
          rest == "" -> :wildcard
          String.contains?(rest, ["*", "/"]) -> :wildcard
          Regex.match?(@tool_name_pattern, rest) and byte_size(rest) <= 128 -> {:tool, rest}
          true -> :other
        end

      true ->
        :other
    end
  end

  defp classify(_), do: :other

  defp safe_mode(mode_fun, uri) do
    mode_fun.(uri)
  rescue
    _ -> :deny
  catch
    _, _ -> :deny
  end
end

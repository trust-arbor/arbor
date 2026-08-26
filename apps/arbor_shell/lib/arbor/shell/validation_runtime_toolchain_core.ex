defmodule Arbor.Shell.ValidationRuntimeToolchainCore do
  @moduledoc """
  Pure parser for validation-runtime toolchain pins.

  Reads already-loaded `.tool-versions` and Containerfile text. Performs no
  filesystem IO.
  """

  @tool_versions_erlang ~r/^erlang[ \t]+(\S+)\s*$/m
  @tool_versions_elixir ~r/^elixir[ \t]+(\S+)\s*$/m
  @containerfile_erlang ~r/^ARG ERLANG_VERSION=(\S+)\s*$/m
  @containerfile_elixir ~r/^ARG ELIXIR_VERSION=(\S+)\s*$/m

  @required_labels [
    "org.arbor.validation.schema",
    "org.arbor.validation.role",
    "org.arbor.validation.platform",
    "org.arbor.validation.erlang",
    "org.arbor.validation.elixir",
    "org.arbor.validation.mix-lock-sha256",
    "org.arbor.validation.deps-tree-sha256"
  ]

  @type toolchain :: %{erlang: String.t(), elixir: String.t()}

  @spec parse_tool_versions(term()) :: {:ok, toolchain()} | {:error, atom()}
  def parse_tool_versions(text) when is_binary(text) do
    with {:ok, erlang} <- capture(@tool_versions_erlang, text, :missing_tool_versions_erlang),
         {:ok, elixir} <- capture(@tool_versions_elixir, text, :missing_tool_versions_elixir) do
      {:ok, %{erlang: erlang, elixir: elixir}}
    end
  end

  def parse_tool_versions(_text), do: {:error, :invalid_tool_versions}

  @spec parse_containerfile_arg_defaults(term()) :: {:ok, toolchain()} | {:error, atom()}
  def parse_containerfile_arg_defaults(text) when is_binary(text) do
    with {:ok, erlang} <-
           capture(@containerfile_erlang, text, :missing_containerfile_erlang_arg),
         {:ok, elixir} <-
           capture(@containerfile_elixir, text, :missing_containerfile_elixir_arg) do
      {:ok, %{erlang: erlang, elixir: elixir}}
    end
  end

  def parse_containerfile_arg_defaults(_text), do: {:error, :invalid_containerfile}

  @spec require_attestation_labels(term()) :: :ok | {:error, atom()}
  def require_attestation_labels(text) when is_binary(text) do
    missing =
      Enum.reject(@required_labels, fn label ->
        String.contains?(text, label)
      end)

    if missing == [] do
      :ok
    else
      {:error, :missing_validation_label}
    end
  end

  def require_attestation_labels(_text), do: {:error, :invalid_containerfile}

  @spec compare(toolchain(), toolchain()) :: :ok | {:error, :toolchain_drift}
  def compare(%{erlang: erlang, elixir: elixir}, %{erlang: erlang, elixir: elixir}), do: :ok
  def compare(_left, _right), do: {:error, :toolchain_drift}

  @spec guest_platform_for_architecture(term()) :: {:ok, String.t()} | {:error, atom()}
  def guest_platform_for_architecture(arch) when is_binary(arch) do
    trimmed = String.trim(arch)

    cond do
      String.starts_with?(trimmed, "x86_64") or String.starts_with?(trimmed, "amd64") ->
        {:ok, "linux/amd64"}

      String.starts_with?(trimmed, "aarch64") or String.starts_with?(trimmed, "arm64") ->
        {:ok, "linux/arm64"}

      true ->
        {:error, :unsupported_system_architecture}
    end
  end

  def guest_platform_for_architecture(_arch), do: {:error, :unsupported_system_architecture}

  defp capture(regex, text, missing) do
    case Regex.run(regex, text, capture: :all_but_first) do
      [value] when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, missing}
    end
  end
end

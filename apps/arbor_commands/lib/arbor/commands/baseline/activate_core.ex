defmodule Arbor.Commands.Baseline.ActivateCore do
  @moduledoc """
  Pure path decisions for `mix arbor.baseline.activate`.

  Activate never fetches, compiles, or talks to a registry. Those effects
  are not represented here.
  """

  @hex64_re ~r/\A[0-9a-f]{64}\z/

  @spec require_digest(term()) :: {:ok, String.t()} | {:error, atom()}
  def require_digest(digest) when is_binary(digest) do
    if Regex.match?(@hex64_re, digest),
      do: {:ok, digest},
      else: {:error, :invalid_baseline_digest}
  end

  def require_digest(_digest), do: {:error, :invalid_baseline_digest}

  @spec source_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def source_path(arbor_home, digest) when is_binary(arbor_home) and is_binary(digest) do
    with {:ok, digest} <- require_digest(digest),
         {:ok, home} <- require_absolute(arbor_home) do
      {:ok, Path.join([home, "baseline", digest, "baseline.json"])}
    end
  end

  def source_path(_arbor_home, _digest), do: {:error, :invalid_activate_paths}

  @spec destination_path(String.t(), term()) :: {:ok, String.t()} | {:error, atom()}
  def destination_path(arbor_home, env_override)
      when is_binary(arbor_home) and is_binary(env_override) and env_override != "" do
    require_absolute(env_override)
  end

  def destination_path(arbor_home, _env_override) when is_binary(arbor_home) do
    with {:ok, home} <- require_absolute(arbor_home) do
      {:ok, Path.join(home, "validation-runtime.json")}
    end
  end

  def destination_path(_arbor_home, _env_override), do: {:error, :invalid_activate_paths}

  @spec require_oci_document(term()) :: :ok | {:error, atom()}
  def require_oci_document(%{"runtime" => "oci"} = document) when is_map(document) do
    cond do
      Map.has_key?(document, "apple_container") or
        get_in(document, ["image_policy", "vminit_image"]) != nil or
          get_in(document, ["image_policy", "vminit_manifest_digest"]) != nil ->
        {:error, :apple_only_policy_key}

      not valid_image_id?(get_in(document, ["image_policy", "image_id"])) ->
        {:error, :missing_image_id}

      true ->
        :ok
    end
  end

  def require_oci_document(_document), do: {:error, :invalid_baseline_document}

  defp valid_image_id?("sha256:" <> hex) when byte_size(hex) == 64 do
    Regex.match?(@hex64_re, hex)
  end

  defp valid_image_id?(_other), do: false

  defp require_absolute(path) when is_binary(path) do
    cond do
      path == "" -> {:error, :invalid_path}
      Path.type(path) != :absolute -> {:error, :invalid_path}
      String.contains?(path, ["//", "/./", "/../"]) -> {:error, :invalid_path}
      path != "/" and String.ends_with?(path, "/") -> {:error, :invalid_path}
      true -> {:ok, path}
    end
  end

  defp require_absolute(_path), do: {:error, :invalid_path}
end

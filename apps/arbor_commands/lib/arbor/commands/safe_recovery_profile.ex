defmodule Arbor.Commands.SafeRecoveryProfile do
  @moduledoc """
  Imperative shell for the E0B1 safe-recovery profile evidence.

  Production reads only the fixed reviewed candidate at
  `apps/arbor_commands/priv/packaging/safe_recovery_profile.v1.json`.
  `run/1` admits only CLI-facing options; a synthetic profile is confined
  to `run_for_test/1`.

  The 256 KiB ceiling is a protective outer bound over the frozen 40-entry
  v1 shape: 40 entries times Encode's 4,000-byte rationale limit, rounded
  to 4,096 bytes, plus keys, structure, and headroom. The reader always
  reads at most ceiling+1 bytes so a lying or racing stat cannot force an
  unbounded read.
  """

  alias Arbor.Commands.PackagingRoot
  alias Arbor.Commands.SafeRecoveryProfile.{Core, Encode}
  alias Arbor.Common.SafePath

  @default_profile_rel "apps/arbor_commands/priv/packaging/safe_recovery_profile.v1.json"
  @max_profile_bytes 256 * 1024

  @production_opt_keys MapSet.new([:mode, :json, :root])
  @test_opt_keys MapSet.union(@production_opt_keys, MapSet.new([:profile]))

  @default_opts %{mode: "report", json: false, root: nil, profile: nil}

  @ordered_lists [
    {"selected_applications", "name"},
    {"mandatory_host_responsibilities", "id"},
    {"forbidden_facilities", "id"},
    {"expected_external_dependencies", "id"},
    {"blockers", "id"}
  ]

  @doc """
  Admit the fixed reviewed safe-recovery candidate from a trusted root.

  Accepted options are `:mode`, `:json`, and `:root` only.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) do
    with {:ok, admitted, seen} <- admit_options(opts, :production) do
      do_run(admitted, seen, allow_synthetic: false)
    end
  end

  @doc false
  @spec run_for_test(keyword()) :: {:ok, map()} | {:error, term()}
  def run_for_test(opts) do
    with {:ok, admitted, seen} <- admit_options(opts, :test) do
      do_run(admitted, seen, allow_synthetic: true)
    end
  end

  @doc false
  @spec default_profile_path() :: String.t()
  def default_profile_path, do: @default_profile_rel

  @doc false
  @spec max_profile_bytes() :: pos_integer()
  def max_profile_bytes, do: @max_profile_bytes

  defp do_run(opts, seen, allow_synthetic: allow_synthetic) do
    with {:ok, root} <- resolve_root(opts.root),
         {:ok, profile, digest} <- load_profile(root, opts, seen, allow_synthetic) do
      build_result(opts, profile, digest)
    end
  end

  defp resolve_root(nil) do
    with {:ok, root} <- PackagingRoot.resolve(nil),
         {:ok, real_root} <- SafePath.resolve_real(root) do
      {:ok, real_root}
    else
      {:error, :not_found} -> {:error, :invalid_root_marker}
      {:error, _} = error -> error
    end
  end

  defp resolve_root(path) do
    with {:ok, root} <- PackagingRoot.resolve(path),
         :ok <- reject_root_symlink(root),
         {:ok, real_root} <- SafePath.resolve_real(root) do
      {:ok, real_root}
    else
      {:error, :not_found} -> {:error, :invalid_root_marker}
      {:error, _} = error -> error
    end
  end

  defp reject_root_symlink(root) do
    case File.read_link(root) do
      {:ok, _} -> {:error, :root_symlink_redirection}
      {:error, :einval} -> :ok
      {:error, :enoent} -> {:error, :invalid_root_marker}
      {:error, reason} -> {:error, {:root_read_link, reason}}
    end
  end

  defp load_profile(root, opts, seen, true) do
    if MapSet.member?(seen, :profile) do
      admit_profile(opts.profile)
    else
      load_fixed_profile(root)
    end
  end

  defp load_profile(root, _opts, _seen, false), do: load_fixed_profile(root)

  defp load_fixed_profile(root) do
    with {:ok, path} <- resolve_profile_path(root),
         {:ok, stat} <- stat_profile(path),
         :ok <- require_regular(stat),
         {:ok, bytes} <- read_profile_bytes(path),
         {:ok, decoded} <- decode_profile(bytes) do
      admit_profile(decoded)
    end
  end

  defp resolve_profile_path(root) do
    with {:ok, lexical} <- SafePath.safe_join(root, @default_profile_rel),
         :ok <- require_within(lexical, root),
         {:ok, real} <- resolve_profile_real(lexical),
         :ok <- require_within(real, root),
         :ok <- require_unredirected(lexical, real) do
      {:ok, lexical}
    else
      {:error, :path_traversal} -> {:error, :profile_path_escape}
      {:error, _} = error -> error
    end
  end

  defp require_within(path, root) do
    if SafePath.within?(path, root), do: :ok, else: {:error, :profile_path_escape}
  end

  defp resolve_profile_real(path) do
    case SafePath.resolve_real(path) do
      {:ok, real} -> {:ok, real}
      {:error, :not_found} -> {:error, :profile_missing}
    end
  end

  defp require_unredirected(path, path), do: :ok
  defp require_unredirected(_lexical, _real), do: {:error, :profile_symlink_redirection}

  defp stat_profile(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> {:error, :profile_missing}
      {:error, reason} -> {:error, {:profile_stat, reason}}
    end
  end

  defp require_regular(%File.Stat{type: :regular}), do: :ok
  defp require_regular(%File.Stat{}), do: {:error, :profile_not_regular}

  defp read_profile_bytes(path) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          case :file.read(io, @max_profile_bytes + 1) do
            {:ok, bytes} -> admit_read_bytes(bytes)
            :eof -> {:ok, ""}
            {:error, reason} -> {:error, {:profile_read, reason}}
          end
        after
          :file.close(io)
        end

      {:error, reason} ->
        {:error, {:profile_read, reason}}
    end
  end

  defp admit_read_bytes(bytes) when byte_size(bytes) > @max_profile_bytes,
    do: {:error, :profile_too_large}

  defp admit_read_bytes(bytes), do: {:ok, bytes}

  defp decode_profile(bytes) do
    case Jason.decode(bytes) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :profile_invalid_json}
    end
  end

  defp admit_profile(decoded) do
    with {:ok, projected} <- Core.project(decoded),
         :ok <- require_canonical_order(decoded, projected),
         :ok <- Encode.validate_profile(projected),
         {:ok, digest} <- Encode.profile_digest(projected) do
      {:ok, projected, digest}
    end
  end

  defp require_canonical_order(decoded, projected) do
    Enum.reduce_while(@ordered_lists, :ok, fn {field, id_key}, :ok ->
      decoded_ids = identifier_sequence(fetch_list(decoded, field), id_key)
      projected_ids = Enum.map(Map.fetch!(projected, field), & &1[id_key])

      if decoded_ids == projected_ids do
        {:cont, :ok}
      else
        {:halt, {:error, {:candidate_not_canonical, field}}}
      end
    end)
  end

  defp fetch_list(map, field) do
    case Map.fetch(map, field) do
      {:ok, list} -> list
      :error -> Map.get(map, list_field_atom(field))
    end
  end

  defp list_field_atom("selected_applications"), do: :selected_applications
  defp list_field_atom("mandatory_host_responsibilities"), do: :mandatory_host_responsibilities
  defp list_field_atom("forbidden_facilities"), do: :forbidden_facilities
  defp list_field_atom("expected_external_dependencies"), do: :expected_external_dependencies
  defp list_field_atom("blockers"), do: :blockers

  defp identifier_sequence(list, id_key) when is_list(list) do
    Enum.map(list, fn
      item when is_map(item) ->
        Map.get(item, id_key) || Map.get(item, identifier_atom(id_key))

      _ ->
        :invalid
    end)
  end

  defp identifier_sequence(_, _), do: :invalid

  defp identifier_atom("name"), do: :name
  defp identifier_atom("id"), do: :id

  defp build_result(opts, profile, digest) do
    output = if opts.json, do: "json", else: "human"

    {:ok,
     %{
       "mode" => opts.mode,
       "output" => output,
       "profile" => profile,
       "profile_digest" => digest
     }}
  end

  defp admit_options(opts, kind) when is_list(opts) do
    allowed = if kind == :production, do: @production_opt_keys, else: @test_opt_keys

    Enum.reduce_while(opts, {:ok, @default_opts, MapSet.new()}, fn option,
                                                                   {:ok, admitted, seen} ->
      admit_option(option, admitted, seen, allowed, kind)
    end)
  end

  defp admit_options(_opts, _kind), do: {:error, :invalid_opts}

  defp admit_option({key, value}, admitted, seen, allowed, kind) when is_atom(key) do
    cond do
      MapSet.member?(seen, key) ->
        {:halt, {:error, {:duplicate_option, key}}}

      not MapSet.member?(allowed, key) ->
        {:halt, unknown_option(kind, key)}

      true ->
        case validate_option(key, value) do
          :ok ->
            {:cont, {:ok, Map.put(admitted, key, value), MapSet.put(seen, key)}}

          {:error, _} = error ->
            {:halt, error}
        end
    end
  end

  defp admit_option(_option, _admitted, _seen, _allowed, _kind),
    do: {:halt, {:error, :invalid_opts}}

  defp unknown_option(:production, key),
    do: {:error, {:production_opts_forbid_synthetic, [key]}}

  defp unknown_option(:test, key), do: {:error, {:unknown_option, key}}

  defp validate_option(:mode, mode) when mode in ["report", "check"], do: :ok
  defp validate_option(:json, json) when is_boolean(json), do: :ok
  defp validate_option(:root, nil), do: :ok
  defp validate_option(:root, value) when is_binary(value), do: :ok

  defp validate_option(:profile, profile) when is_map(profile) and not is_struct(profile),
    do: :ok

  defp validate_option(key, _value), do: {:error, {:invalid_option, key}}
end

defmodule Arbor.Commands.SafeRecoveryArtifact.Classify do
  @moduledoc false

  import Bitwise

  @cpu_arm64 0x0100000C
  @mh_magic_64 0xFEEDFACF
  @mh_cigam_64 0xCFFAEDFE
  @mh_magic 0xFEEDFACE
  @mh_cigam 0xCEFAEDFE
  @fat_magic 0xCAFEBABE
  @fat_cigam 0xBEBAFECA
  @fat_magic_64 0xCAFEBABF
  @fat_cigam_64 0xBFBAFECA
  @max_fat_arch 8
  @prefix_max 256
  @thin64_header 32
  @fat_header 8
  @fat32_arch 20
  @fat64_arch 32

  @attr_keys [:executable, :identities, :owner, :path, :prefix, :size, :term_role]

  @doc """
  Classify one regular-file prefix. Required atom keys: path, size, prefix,
  executable, term_role, owner, identities. Locked order: cookie, FOR1/BEAM,
  thin/fat Mach-O, ELF, PE, then .beam/.app/.rel role, executable, priv,
  releases/, other. Missing, extra, or mistyped attrs return an error.
  """
  @spec kind(map()) :: {:ok, String.t()} | {:error, atom()}
  def kind(attrs) when is_map(attrs) and not is_struct(attrs) do
    case admit_attrs(attrs) do
      {:ok, admitted} -> classify_admitted(admitted)
      {:error, reason} -> {:error, reason}
    end
  end

  def kind(_), do: {:error, :malformed_signature}

  defp admit_attrs(attrs) do
    keys = Map.keys(attrs)

    cond do
      MapSet.new(keys) != MapSet.new(@attr_keys) ->
        {:error, :malformed_signature}

      not attr_types?(attrs) ->
        {:error, :malformed_signature}

      true ->
        {:ok, attrs}
    end
  end

  defp attr_types?(attrs) do
    is_binary(attrs[:path]) and is_integer(attrs[:size]) and attrs[:size] >= 0 and
      is_binary(attrs[:prefix]) and is_boolean(attrs[:executable]) and
      attrs[:term_role] in [:app, :rel, nil] and
      (is_nil(attrs[:owner]) or is_binary(attrs[:owner])) and
      identities_ok?(attrs[:identities])
  end

  defp identities_ok?(list) when is_list(list) do
    Enum.all?(list, fn
      {name, vsn} when is_binary(name) and is_binary(vsn) -> true
      _other -> false
    end)
  end

  defp identities_ok?(_), do: false

  defp classify_admitted(attrs) do
    path = attrs[:path]
    size = attrs[:size]
    prefix = attrs[:prefix]
    executable? = attrs[:executable]
    term_role = attrs[:term_role]
    owner = attrs[:owner]
    identities = attrs[:identities]

    cond do
      path == "releases/COOKIE" ->
        {:error, :cookie_present}

      for1?(prefix) ->
        classify_beam(path, size, prefix)

      thin64?(prefix) ->
        classify_thin64(path, size, prefix)

      thin32?(prefix) ->
        {:error, :target_mismatch}

      fat?(prefix) ->
        classify_fat(path, size, prefix)

      elf?(prefix) ->
        {:error, :target_mismatch}

      pe?(prefix) ->
        {:error, :target_mismatch}

      true ->
        classify_path(path, executable?, term_role, owner, identities)
    end
  end

  defp for1?(<<"FOR1", _::binary>>), do: true
  defp for1?(_), do: false

  defp thin64?(<<magic::unsigned-big-32, _::binary>>)
       when magic in [@mh_magic_64, @mh_cigam_64],
       do: true

  defp thin64?(_), do: false

  defp thin32?(<<magic::unsigned-big-32, _::binary>>)
       when magic in [@mh_magic, @mh_cigam],
       do: true

  defp thin32?(_), do: false

  defp fat?(<<magic::unsigned-big-32, _::binary>>)
       when magic in [@fat_magic, @fat_cigam, @fat_magic_64, @fat_cigam_64],
       do: true

  defp fat?(_), do: false

  defp elf?(<<0x7F, "ELF", _::binary>>), do: true
  defp elf?(_), do: false

  defp pe?(<<"MZ", _::binary>>), do: true
  defp pe?(_), do: false

  defp classify_beam(path, size, prefix) do
    with :ok <- require_suffix(path, ".beam"),
         :ok <- beam_framing(size, prefix) do
      {:ok, "beam"}
    end
  end

  defp beam_framing(size, _prefix) when size < 12, do: {:error, :truncated_beam}

  defp beam_framing(size, <<"FOR1", declared::unsigned-big-32, "BEAM", _::binary>>) do
    if size == declared + 8, do: :ok, else: beam_size_error(size, declared)
  end

  defp beam_framing(_size, <<"FOR1", _::binary>>), do: {:error, :malformed_signature}
  defp beam_framing(_size, _prefix), do: {:error, :malformed_signature}

  defp beam_size_error(size, declared) when size < declared + 8, do: {:error, :truncated_beam}
  defp beam_size_error(_size, _declared), do: {:error, :malformed_signature}

  defp classify_thin64(path, size, prefix) do
    with :ok <- reject_native_suffix(path),
         :ok <- thin64_header(size, prefix) do
      {:ok, "native"}
    end
  end

  defp thin64_header(size, prefix)
       when size < @thin64_header or byte_size(prefix) < @thin64_header do
    {:error, :malformed_signature}
  end

  defp thin64_header(_size, <<magic::unsigned-big-32, rest::binary>>) do
    endian = thin_endian(magic)
    decode_thin_cputype(endian, rest)
  end

  defp thin_endian(@mh_magic_64), do: :big
  defp thin_endian(@mh_cigam_64), do: :little

  defp decode_thin_cputype(:little, <<cputype::unsigned-little-32, _::binary>>) do
    admit_arm64(cputype)
  end

  defp decode_thin_cputype(:big, <<cputype::unsigned-big-32, _::binary>>) do
    admit_arm64(cputype)
  end

  defp decode_thin_cputype(_endian, _rest), do: {:error, :malformed_signature}

  defp admit_arm64(@cpu_arm64), do: :ok
  defp admit_arm64(_), do: {:error, :target_mismatch}

  defp classify_fat(path, size, prefix) do
    with :ok <- reject_native_suffix(path),
         {:ok, slices} <- parse_fat_table(size, prefix),
         :ok <- admit_fat_slices(slices) do
      {:ok, "native"}
    end
  end

  defp parse_fat_table(size, <<magic::unsigned-big-32, _::binary>> = prefix) do
    {endian, rec_size} = fat_layout(magic)
    parse_fat_header(endian, rec_size, size, prefix)
  end

  defp fat_layout(@fat_magic), do: {:big, @fat32_arch}
  defp fat_layout(@fat_cigam), do: {:little, @fat32_arch}
  defp fat_layout(@fat_magic_64), do: {:big, @fat64_arch}
  defp fat_layout(@fat_cigam_64), do: {:little, @fat64_arch}

  defp parse_fat_header(endian, rec_size, file_size, prefix) do
    with {:ok, nfat} <- read_nfat(endian, prefix),
         :ok <- admit_nfat(nfat),
         table_size = @fat_header + nfat * rec_size,
         :ok <- table_fits(table_size, prefix, file_size),
         {:ok, records} <- read_fat_records(endian, rec_size, nfat, prefix) do
      validate_fat_records(records, table_size, file_size)
    end
  end

  defp read_nfat(:big, <<_magic::32, nfat::unsigned-big-32, _::binary>>), do: {:ok, nfat}
  defp read_nfat(:little, <<_magic::32, nfat::unsigned-little-32, _::binary>>), do: {:ok, nfat}
  defp read_nfat(_endian, _prefix), do: {:error, :malformed_signature}

  defp admit_nfat(nfat) when nfat >= 1 and nfat <= @max_fat_arch, do: :ok
  defp admit_nfat(_), do: {:error, :malformed_signature}

  defp table_fits(table_size, prefix, file_size) do
    available = min(@prefix_max, min(byte_size(prefix), file_size))

    if table_size <= available, do: :ok, else: {:error, :malformed_signature}
  end

  defp read_fat_records(endian, rec_size, nfat, prefix) do
    table = binary_part(prefix, @fat_header, nfat * rec_size)
    split_records(table, rec_size, endian, [])
  end

  defp split_records(<<>>, _rec_size, _endian, acc), do: {:ok, Enum.reverse(acc)}

  defp split_records(table, rec_size, endian, acc) do
    <<record::binary-size(rec_size), rest::binary>> = table

    case decode_fat_record(endian, rec_size, record) do
      {:ok, decoded} -> split_records(rest, rec_size, endian, [decoded | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_fat_record(:big, @fat32_arch, <<
         cputype::unsigned-big-32,
         _subtype::unsigned-big-32,
         offset::unsigned-big-32,
         size::unsigned-big-32,
         align::unsigned-big-32
       >>) do
    {:ok, %{cputype: cputype, offset: offset, size: size, align: align, reserved: 0}}
  end

  defp decode_fat_record(:little, @fat32_arch, <<
         cputype::unsigned-little-32,
         _subtype::unsigned-little-32,
         offset::unsigned-little-32,
         size::unsigned-little-32,
         align::unsigned-little-32
       >>) do
    {:ok, %{cputype: cputype, offset: offset, size: size, align: align, reserved: 0}}
  end

  defp decode_fat_record(:big, @fat64_arch, <<
         cputype::unsigned-big-32,
         _subtype::unsigned-big-32,
         offset::unsigned-big-64,
         size::unsigned-big-64,
         align::unsigned-big-32,
         reserved::unsigned-big-32
       >>) do
    {:ok, %{cputype: cputype, offset: offset, size: size, align: align, reserved: reserved}}
  end

  defp decode_fat_record(:little, @fat64_arch, <<
         cputype::unsigned-little-32,
         _subtype::unsigned-little-32,
         offset::unsigned-little-64,
         size::unsigned-little-64,
         align::unsigned-little-32,
         reserved::unsigned-little-32
       >>) do
    {:ok, %{cputype: cputype, offset: offset, size: size, align: align, reserved: reserved}}
  end

  defp decode_fat_record(_endian, _rec_size, _record), do: {:error, :malformed_signature}

  defp validate_fat_records(records, table_size, file_size) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, seen} ->
      case admit_fat_record(record, table_size, file_size, seen) do
        {:ok, next} -> {:cont, {:ok, [next | seen]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_seen()
  end

  defp reverse_seen({:ok, seen}), do: {:ok, Enum.reverse(seen)}
  defp reverse_seen(error), do: error

  defp admit_fat_record(record, table_size, file_size, seen) do
    with :ok <- reserved_ok(record),
         :ok <- size_ok(record),
         :ok <- align_ok(record),
         :ok <- range_ok(record, table_size, file_size),
         :ok <- no_overlap(record, seen) do
      {:ok, record}
    end
  end

  defp reserved_ok(%{reserved: 0}), do: :ok
  defp reserved_ok(_), do: {:error, :malformed_signature}

  defp size_ok(%{size: size}) when size > 0, do: :ok
  defp size_ok(_), do: {:error, :malformed_signature}

  defp align_ok(%{align: align, offset: offset})
       when is_integer(align) and align >= 0 and align <= 31 do
    if rem(offset, 1 <<< align) == 0, do: :ok, else: {:error, :malformed_signature}
  end

  defp align_ok(_), do: {:error, :malformed_signature}

  defp range_ok(%{offset: offset, size: size}, table_size, file_size) do
    sum = offset + size

    cond do
      offset < table_size -> {:error, :malformed_signature}
      sum < offset -> {:error, :malformed_signature}
      sum > file_size -> {:error, :malformed_signature}
      true -> :ok
    end
  end

  defp no_overlap(%{offset: offset, size: size}, seen) do
    last = offset + size

    conflict =
      Enum.any?(seen, fn other ->
        (other.offset == offset and other.size == size) or ranges_overlap?(offset, last, other)
      end)

    if conflict, do: {:error, :malformed_signature}, else: :ok
  end

  defp ranges_overlap?(start, last, other) do
    other_last = other.offset + other.size
    start < other_last and other.offset < last
  end

  defp admit_fat_slices(slices) do
    if Enum.any?(slices, &(&1.cputype == @cpu_arm64)) do
      :ok
    else
      {:error, :target_mismatch}
    end
  end

  defp classify_path(path, executable?, term_role, owner, identities) do
    cond do
      String.ends_with?(path, ".beam") ->
        {:error, :suffix_signature_mismatch}

      term_role == :app ->
        {:ok, "app_spec"}

      term_role == :rel ->
        {:ok, "release_metadata"}

      String.ends_with?(path, ".app") or String.ends_with?(path, ".rel") ->
        {:error, :suffix_signature_mismatch}

      executable? ->
        {:ok, "executable"}

      priv_asset?(path, owner, identities) ->
        {:ok, "private_asset"}

      String.starts_with?(path, "releases/") ->
        {:ok, "release_metadata"}

      true ->
        {:ok, "other"}
    end
  end

  defp require_suffix(path, suffix) do
    if String.ends_with?(path, suffix), do: :ok, else: {:error, :suffix_signature_mismatch}
  end

  defp reject_native_suffix(path) do
    if String.ends_with?(path, ".beam") or String.ends_with?(path, ".app") or
         String.ends_with?(path, ".rel") do
      {:error, :suffix_signature_mismatch}
    else
      :ok
    end
  end

  defp priv_asset?(_path, nil, _identities), do: false
  defp priv_asset?(_path, _owner, identities) when not is_list(identities), do: false

  defp priv_asset?(path, owner, identities) when is_binary(owner) do
    case identity_for(owner, identities) do
      {:ok, name, vsn} -> String.starts_with?(path, "lib/" <> name <> "-" <> vsn <> "/priv/")
      :error -> false
    end
  end

  defp priv_asset?(_path, _owner, _identities), do: false

  defp identity_for(owner, identities) do
    Enum.find_value(identities, :error, fn
      {name, vsn} when name == owner and is_binary(vsn) -> {:ok, name, vsn}
      _other -> nil
    end)
  end
end

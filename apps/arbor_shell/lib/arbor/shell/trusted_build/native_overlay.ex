defmodule Arbor.Shell.TrustedBuild.NativeOverlay do
  @moduledoc false

  @schema "arbor.packaging.safe_recovery_native_overlay.v1"
  @name "sqlite_vec"
  @overlay_version 1
  @native_version "0.1.5"
  @hex_package "sqlite_vec"
  @hex_version "0.1.0"
  @target "aarch64-apple-darwin"
  @filename "vec0.dylib"
  @logical_path "deps/sqlite_vec/priv/0.1.5/vec0.dylib"
  @staging_rel "native_overlay/v1/aarch64-apple-darwin/sqlite_vec/0.1.5/vec0.dylib"
  @dest_rel "sqlite_vec/priv/0.1.5/vec0.dylib"
  @cookie_rel "rel/arbor_trust/releases/COOKIE"
  @cookie_inventory_path "arbor_trust/releases/COOKIE"
  @size 126_600
  @sha256 "45d67c7868152c1b9b4b86cd1cea1d8834136e13f8e0348648b89f8aa90e7b5b"

  @spec descriptor() :: map()
  def descriptor do
    %{
      "schema" => @schema,
      "name" => @name,
      "overlay_version" => @overlay_version,
      "native_version" => @native_version,
      "hex_package" => @hex_package,
      "hex_version" => @hex_version,
      "target" => @target,
      "filename" => @filename,
      "logical_path" => @logical_path,
      "staging_rel" => @staging_rel,
      "dest_rel" => @dest_rel,
      "size" => @size,
      "sha256" => @sha256
    }
  end

  @spec staging_rel() :: String.t()
  def staging_rel, do: @staging_rel

  @spec dest_rel() :: String.t()
  def dest_rel, do: @dest_rel

  @spec cookie_rel() :: String.t()
  def cookie_rel, do: @cookie_rel

  @spec cookie_inventory_path() :: String.t()
  def cookie_inventory_path, do: @cookie_inventory_path

  @spec size() :: pos_integer()
  def size, do: @size

  @spec sha256() :: String.t()
  def sha256, do: @sha256

  @spec staging_segments() :: [String.t()]
  def staging_segments, do: Path.split(@staging_rel)

  @spec dest_segments() :: [String.t()]
  def dest_segments, do: Path.split(@dest_rel)

  @spec cookie_segments() :: [String.t()]
  def cookie_segments, do: Path.split(@cookie_rel)

  @spec matches_pin?(map()) :: boolean()
  def matches_pin?(%{size: size, sha256: digest})
      when size == @size and digest == @sha256,
      do: true

  def matches_pin?(_identity), do: false
end

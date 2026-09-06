defmodule Depdep.Provider.Apt do
  @moduledoc """
  Debian packages, cached so a job does not re-download them from a mirror.

  The flow this serves runs an off-the-shelf container and apt-installs a few
  packages in the CI script. **Depdep therefore runs in the same apt environment
  as the install it is serving**, which is what makes this simple: `apt-get
  install --print-uris` is not a guess about what some other image would resolve,
  it is apt itself reporting what it is about to fetch, in the environment that
  will fetch it.

  Restore drops those files into the archives directory; `apt-get install` looks
  there before it reaches for the network. **Depdep's responsibility ends at
  populating a directory** — nothing here runs apt-get install, edits sources, or
  takes a view on the consumer's pipeline.

  ## Nothing here recurses, and that is not a shortcut

  `Depdep.Key` recurses because an Elixir dependency's compiled output is a
  function of its dependencies' compiled output: bump spark and ash's correct
  bytecode changes while ash's own version does not. A `.deb` has no such
  property. It is built once by the distribution for everyone, its contents do
  not change when its dependencies change, and `name_version_arch.deb` already
  identifies it exactly. **So the key IS the filename.** A flat key is the
  correct key here, not a compromise on the way to a better one.

  ## Enumeration depends on the direction

  A pull asks apt what it WILL fetch. A push asks the directory what WAS
  fetched. Those are different questions, and the difference is not academic:
  once `apt-get install` has run, `--print-uris` reports nothing at all, because
  the packages are installed and apt has nothing left to fetch. A provider that
  enumerated the same way in both directions would push nothing, and would do it
  silently.
  """

  @behaviour Depdep.Provider

  alias Depdep.Unit

  # Its own prefix, so apt objects can be retired without touching the `v2/`
  # Mix ones. The suite is in the path because two distributions can ship the
  # same filename, and because a store you cannot browse is a store you cannot
  # audit.
  @prefix "apt/v1"

  @default_dir "/var/cache/apt/archives"

  @impl true
  def enumerate(opts) do
    dir = Keyword.get(opts, :apt_cache_dir, @default_dir)

    case Keyword.get(opts, :direction, :pull) do
      :push -> from_directory(dir)
      _ -> from_apt(Keyword.get_values(opts, :package), dir)
    end
  end

  # ── pull: ask apt what it is about to fetch ───────────────────────────────

  defp from_apt([], _dir),
    do: {:ok, [], ["apt: no --package given, so there is nothing to restore"]}

  defp from_apt(packages, dir) do
    cond do
      System.find_executable("apt-get") == nil ->
        {:ok, [], ["apt: no apt-get on this machine — nothing to restore"]}

      true ->
        args = ["install", "--print-uris", "-qq", "-y"] ++ packages

        case System.cmd("apt-get", args, stderr_to_stdout: false) do
          {output, 0} ->
            {:ok, output |> parse_uris() |> Enum.map(&unit(&1, dir)), []}

          {_output, status} ->
            {:ok, [],
             [
               "apt: `apt-get install --print-uris` exited #{status} — " <>
                 "packages will be downloaded as usual (has `apt-get update` run?)"
             ]}
        end
    end
  end

  @doc """
  Parses `apt-get install --print-uris` output.

      'http://deb.debian.org/debian/pool/main/c/coreutils/coreutils_9.7-3_amd64.deb' coreutils_9.7-3_amd64.deb 3023556 MD5Sum:4a48f6...

  Public because this is the whole contract with apt and the only part of this
  provider that can be tested without a package manager and a network. The
  checksum algorithm is whatever apt names — MD5Sum on Debian trixie, SHA256 on
  others — so it is read from the line rather than assumed.
  """
  def parse_uris(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, " ", trim: true) do
        [_uri, filename, size, checksum] ->
          [%{filename: filename, size: size, checksum: parse_checksum(checksum)}]

        _ ->
          []
      end
    end)
  end

  defp parse_checksum(field) do
    case String.split(field, ":", parts: 2) do
      [algorithm, hex] -> {algorithm |> String.downcase() |> String.trim_trailing("sum"), hex}
      _ -> nil
    end
  end

  # ── push: ask the directory what was fetched ──────────────────────────────

  defp from_directory(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        units =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".deb"))
          |> Enum.sort()
          |> Enum.map(&unit(%{filename: &1, size: nil, checksum: nil}, dir))

        {:ok, units, []}

      {:error, reason} ->
        {:ok, [], ["apt: cannot read #{dir} (#{:file.format_error(reason)}) — nothing to upload"]}
    end
  end

  # ── units ─────────────────────────────────────────────────────────────────

  defp unit(%{filename: filename} = package, dir) do
    %Unit{
      name: filename,
      detail: package.size || "-",
      # The key of an apt object is its filename: `name_version_arch.deb` is
      # unique by construction, so there is nothing to hash.
      resolution: {:key, filename},
      object: "#{@prefix}/#{suite()}/#{filename}",
      context: %{dir: dir, filename: filename, checksum: package.checksum}
    }
  end

  @doc """
  The distribution this machine is, as `debian-trixie`.

  Two distributions can ship a file of the same name, so the suite is part of
  every object path. Unknown rather than guessed when `/etc/os-release` is
  absent: a wrong suite would mix two distributions' packages in one prefix.
  """
  def suite do
    case File.read("/etc/os-release") do
      {:ok, contents} ->
        fields = os_release_fields(contents)
        "#{fields["ID"] || "unknown"}-#{fields["VERSION_CODENAME"] || "unknown"}"

      {:error, _} ->
        "unknown-unknown"
    end
  end

  defp os_release_fields(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> [{key, value |> String.trim() |> String.trim(~s("))}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  # ── the seam ──────────────────────────────────────────────────────────────

  @impl true
  def present?(%Unit{context: %{dir: dir, filename: filename}}),
    do: File.regular?(Path.join(dir, filename))

  @doc """
  Verifies the fetched file before handing it to a package manager.

  A capability the Mix provider does not have and gets for free here: apt has
  already told us each file's checksum, so a corrupt or truncated object is
  caught rather than installed. A mismatch is reported as an ordinary failure,
  which the caller counts as a miss — so apt downloads it, which is what would
  have happened without a store at all.
  """
  @impl true
  def restore(%Unit{context: %{dir: dir, filename: filename, checksum: checksum}}, tmp) do
    case verify(tmp, checksum) do
      :ok ->
        File.mkdir_p!(dir)
        File.rename(tmp, Path.join(dir, filename))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def collect(%Unit{context: %{dir: dir, filename: filename}}, tmp) do
    case File.cp(Path.join(dir, filename), tmp) do
      :ok -> :ok
      {:error, reason} -> {:error, :file.format_error(reason)}
    end
  end

  @doc "Checks a file against `{algorithm, hex}`; anything unknown passes."
  def verify(_path, nil), do: :ok

  def verify(path, {algorithm, expected}) do
    case digest(path, algorithm) do
      nil -> :ok
      ^expected -> :ok
      actual -> {:error, "checksum mismatch: apt expected #{expected}, object is #{actual}"}
    end
  end

  defp digest(path, algorithm) do
    case algorithm do
      "md5" -> hash_file(path, :md5)
      "sha1" -> hash_file(path, :sha)
      "sha256" -> hash_file(path, :sha256)
      "sha512" -> hash_file(path, :sha512)
      _ -> nil
    end
  end

  defp hash_file(path, algorithm) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(algorithm), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end

defmodule Depdep.Provider.AptIntegrationTest do
  @moduledoc """
  The apt contract, against a real apt.

  Every other test in this suite feeds the provider captured output. This one
  asks the actual package manager, because the claim being made is about apt's
  behaviour and not about depdep's: that the filename apt reports in
  `--print-uris` is the filename apt then looks for in its archives directory,
  and that the checksum it reports is the checksum of the file you get.

  Excluded by default — it needs apt-get and a Debian mirror.
  """
  use ExUnit.Case, async: false

  @moduletag :apt_integration

  alias Depdep.Provider.Apt

  # Small, present in every Debian, and never absent from the index.
  @package "coreutils"

  setup_all do
    if System.find_executable("apt-get") == nil do
      raise "apt_integration tests need apt-get on PATH"
    end

    :ok
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "depdep-apt-int-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "apt names a file, and that file verifies against the checksum apt named", %{dir: dir} do
    # `--reinstall` so apt reports the package even though it is already
    # installed on the machine running the suite.
    {output, 0} =
      System.cmd("apt-get", ["install", "--print-uris", "-qq", "-y", "--reinstall", @package])

    assert [package] = Apt.parse_uris(output)
    assert package.filename =~ ~r/^#{@package}_.+_[a-z0-9]+\.deb$/
    assert {_algorithm, _hex} = package.checksum

    # Fetch the very file apt just described, by the means apt itself offers.
    {_, 0} = System.cmd("apt-get", ["download", @package], cd: dir)
    downloaded = Path.join(dir, package.filename)

    assert File.regular?(downloaded),
           "apt-get download produced #{inspect(File.ls!(dir))}, " <>
             "but --print-uris named #{package.filename}"

    # The whole restore path: apt's stated checksum accepts apt's own file.
    assert Apt.verify(downloaded, package.checksum) == :ok
    assert to_string(File.stat!(downloaded).size) == package.size
  end

  test "a real file round-trips through collect and restore, verified", %{dir: dir} do
    {output, 0} =
      System.cmd("apt-get", ["install", "--print-uris", "-qq", "-y", "--reinstall", @package])

    [package] = Apt.parse_uris(output)
    {_, 0} = System.cmd("apt-get", ["download", @package], cd: dir)

    [unit] =
      Apt.enumerate(direction: :push, apt_cache_dir: dir)
      |> then(fn {:ok, units, []} -> units end)

    assert unit.name == package.filename
    assert Apt.present?(unit)

    original = File.read!(Path.join(dir, package.filename))
    tmp = Path.join(System.tmp_dir!(), "depdep-int-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(tmp) end)

    assert Apt.collect(unit, tmp) == :ok
    File.rm!(Path.join(dir, package.filename))
    refute Apt.present?(unit)

    # Restore through the checksum apt stated, not one we computed ourselves.
    verified = put_in(unit.context.checksum, package.checksum)
    assert Apt.restore(verified, tmp) == :ok
    assert Apt.present?(verified)
    assert File.read!(Path.join(dir, package.filename)) == original
  end
end

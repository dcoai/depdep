defmodule Depdep.Provider.AptTest do
  @moduledoc """
  Everything here runs without apt-get, without root and without a network.

  The provider's contract with apt is one line of text per package, so that
  parse is the seam worth testing — the samples below are real
  `apt-get install --print-uris` output, not invented shapes.
  """
  use ExUnit.Case, async: true

  alias Depdep.Provider.Apt
  alias Depdep.Unit

  # Captured from Debian trixie. Note MD5Sum: newer apt emits SHA256, which is
  # why the algorithm is read from the line rather than assumed.
  @print_uris """
  'http://deb.debian.org/debian/pool/main/c/coreutils/coreutils_9.7-3_amd64.deb' coreutils_9.7-3_amd64.deb 3023556 MD5Sum:4a48f61cc5b86a87f14b3d2045c9870f
  'http://deb.debian.org/debian/pool/main/libs/libsodium/libsodium-dev_1.0.18-1_amd64.deb' libsodium-dev_1.0.18-1_amd64.deb 179496 SHA256:deadbeef
  """

  describe "parse_uris/1" do
    test "reads filename, size and checksum, keeping apt's choice of algorithm" do
      assert [coreutils, libsodium] = Apt.parse_uris(@print_uris)

      assert coreutils.filename == "coreutils_9.7-3_amd64.deb"
      assert coreutils.size == "3023556"
      assert coreutils.checksum == {"md5", "4a48f61cc5b86a87f14b3d2045c9870f"}
      assert libsodium.checksum == {"sha256", "deadbeef"}
    end

    # apt says nothing when every requested package is already installed, which
    # is exactly the state a `--push` runs in. Empty must be empty, not a crash.
    test "no output is no units" do
      assert Apt.parse_uris("") == []
      assert Apt.parse_uris("\n\n") == []
    end

    test "a line that is not a package URI is ignored rather than guessed at" do
      assert Apt.parse_uris("Reading package lists...\nBuilding dependency tree\n") == []
    end
  end

  describe "suite/0" do
    test "identifies the distribution, so two of them cannot share a prefix" do
      assert Apt.suite() =~ ~r/^[a-z0-9._]+-[a-z0-9._]+$/
    end
  end

  describe "enumerate/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "depdep-apt-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "a pull with no packages named restores nothing and says so", %{dir: dir} do
      assert {:ok, [], [warning]} =
               Apt.enumerate(direction: :pull, apt_cache_dir: dir)

      assert warning =~ "no --package given"
    end

    # The push side is the one this flow actually leans on: whatever apt left in
    # the archives directory is what the store does not have yet.
    test "a push enumerates the .deb files in the archives directory", %{dir: dir} do
      File.write!(Path.join(dir, "coreutils_9.7-3_amd64.deb"), "one")
      File.write!(Path.join(dir, "libsodium-dev_1.0.18-1_amd64.deb"), "two")
      File.write!(Path.join(dir, "partial.deb.tmp"), "not a package")
      File.write!(Path.join(dir, "lock"), "not a package")

      assert {:ok, units, []} = Apt.enumerate(direction: :push, apt_cache_dir: dir)

      assert Enum.map(units, & &1.name) == [
               "coreutils_9.7-3_amd64.deb",
               "libsodium-dev_1.0.18-1_amd64.deb"
             ]
    end

    test "a missing archives directory is a warning, not a failure" do
      assert {:ok, [], [warning]} =
               Apt.enumerate(direction: :push, apt_cache_dir: "/definitely/not/here")

      assert warning =~ "nothing to upload"
    end

    test "the key is the filename, and the object path carries the suite", %{dir: dir} do
      File.write!(Path.join(dir, "coreutils_9.7-3_amd64.deb"), "one")

      assert {:ok, [unit], []} = Apt.enumerate(direction: :push, apt_cache_dir: dir)

      assert unit.resolution == {:key, "coreutils_9.7-3_amd64.deb"}
      assert unit.object == "apt/v1/#{Apt.suite()}/coreutils_9.7-3_amd64.deb"
      assert unit.group == nil
    end
  end

  describe "verify/2" do
    setup do
      path = Path.join(System.tmp_dir!(), "depdep-verify-#{System.unique_integer([:positive])}")
      File.write!(path, "the package bytes")
      on_exit(fn -> File.rm(path) end)
      %{path: path, md5: :crypto.hash(:md5, "the package bytes") |> Base.encode16(case: :lower)}
    end

    test "accepts a file matching what apt said", %{path: path, md5: md5} do
      assert Apt.verify(path, {"md5", md5}) == :ok
    end

    # A corrupt object must never reach a package manager. Reported as an
    # ordinary failure so the caller counts a miss and apt downloads it — which
    # is what would have happened with no store at all.
    test "rejects a file that does not", %{path: path} do
      assert {:error, reason} = Apt.verify(path, {"md5", "00000000000000000000000000000000"})
      assert reason =~ "checksum mismatch"
    end

    test "passes when apt named no checksum, or one we cannot compute", %{path: path} do
      assert Apt.verify(path, nil) == :ok
      assert Apt.verify(path, {"whirlpool", "abc"}) == :ok
    end
  end

  describe "present?/restore/collect" do
    setup do
      dir = Path.join(System.tmp_dir!(), "depdep-apt-rt-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      unit = %Unit{
        name: "coreutils_9.7-3_amd64.deb",
        resolution: {:key, "coreutils_9.7-3_amd64.deb"},
        object: "apt/v1/debian-trixie/coreutils_9.7-3_amd64.deb",
        context: %{dir: dir, filename: "coreutils_9.7-3_amd64.deb", checksum: nil}
      }

      %{dir: dir, unit: unit}
    end

    test "present? is whether the file is in the archives directory", %{dir: dir, unit: unit} do
      refute Apt.present?(unit)
      File.write!(Path.join(dir, unit.name), "package")
      assert Apt.present?(unit)
    end

    test "collect then restore reproduces the file", %{dir: dir, unit: unit} do
      File.write!(Path.join(dir, unit.name), "package bytes")
      tmp = Path.join(System.tmp_dir!(), "depdep-apt-tmp-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(tmp) end)

      assert Apt.collect(unit, tmp) == :ok
      File.rm!(Path.join(dir, unit.name))
      refute Apt.present?(unit)

      assert Apt.restore(unit, tmp) == :ok
      assert File.read!(Path.join(dir, unit.name)) == "package bytes"
    end

    test "restore creates the archives directory if the image cleaned it away", %{unit: unit} do
      File.rm_rf!(unit.context.dir)
      tmp = Path.join(System.tmp_dir!(), "depdep-apt-tmp-#{System.unique_integer([:positive])}")
      File.write!(tmp, "package bytes")
      on_exit(fn -> File.rm(tmp) end)

      assert Apt.restore(unit, tmp) == :ok
      assert Apt.present?(unit)
    end

    test "restore refuses an object apt's checksum does not match", %{unit: unit} do
      unit = put_in(unit.context.checksum, {"md5", "00000000000000000000000000000000"})
      tmp = Path.join(System.tmp_dir!(), "depdep-apt-tmp-#{System.unique_integer([:positive])}")
      File.write!(tmp, "corrupt")
      on_exit(fn -> File.rm(tmp) end)

      assert {:error, reason} = Apt.restore(unit, tmp)
      assert reason =~ "checksum mismatch"
      refute Apt.present?(unit)
    end
  end
end

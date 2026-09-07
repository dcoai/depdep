defmodule Depdep.S3Test do
  use ExUnit.Case, async: false

  alias Depdep.S3

  # A socket, not a mock. What matters about `put/3` is what goes out on the
  # wire — an exact content-length, a plain body rather than chunked, and every
  # byte of the file — and none of that is observable from the return value.
  # `:httpc` switching to chunked transfer-encoding would silently invalidate
  # the Signature v4 payload hash, so it is asserted here rather than assumed.
  defp capture_request(body_bytes) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listen)
    parent = self()

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen)
      raw = read_until(sock, "", body_bytes)
      :gen_tcp.send(sock, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
      :gen_tcp.close(sock)
      :gen_tcp.close(listen)
      send(parent, {:request, raw})
    end)

    await = fn ->
      receive do
        {:request, raw} -> raw
      after
        5000 -> flunk("the server never received a complete request")
      end
    end

    {port, await}
  end

  # Reads until the head plus the declared body length have arrived.
  defp read_until(sock, acc, body_bytes) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [_head, body] when byte_size(body) >= body_bytes ->
        acc

      _ ->
        case :gen_tcp.recv(sock, 0, 3000) do
          {:ok, chunk} -> read_until(sock, acc <> chunk, body_bytes)
          {:error, _} -> acc
        end
    end
  end

  defp config(port) do
    %{
      endpoint: "http://127.0.0.1:#{port}",
      bucket: "bucket",
      access_key: "key",
      secret_key: "secret",
      region: "us-east-1",
      host_header: "127.0.0.1:#{port}"
    }
  end

  setup do
    S3.start()
    :ok
  end

  describe "put/3" do
    test "streams the whole file with an exact content-length and no chunking" do
      # Larger than the 64 KiB read chunk, so the body genuinely spans several
      # calls to the body function rather than fitting in one.
      content = :crypto.strong_rand_bytes(200_000)
      path = Path.join(System.tmp_dir!(), "depdep-put-#{System.unique_integer([:positive])}")
      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)

      {port, await} = capture_request(byte_size(content))
      assert S3.put(config(port), "v2/some/object.tar.gz", path) == :ok

      [head, body] = String.split(await.(), "\r\n\r\n", parts: 2)
      head = String.downcase(head)

      assert body == content
      assert head =~ "content-length: #{byte_size(content)}"
      refute head =~ "transfer-encoding: chunked"
    end

    test "signs the streamed body with the hash of the file, not of the empty string" do
      content = "the archive bytes"
      path = Path.join(System.tmp_dir!(), "depdep-sig-#{System.unique_integer([:positive])}")
      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)

      expected = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      {port, await} = capture_request(byte_size(content))
      assert S3.put(config(port), "v2/some/object.tar.gz", path) == :ok

      head = await.() |> String.split("\r\n\r\n", parts: 2) |> hd() |> String.downcase()
      assert head =~ "x-amz-content-sha256: #{expected}"
    end
  end

  describe "concurrency/0" do
    test "is derived, and bounded at both ends" do
      assert S3.concurrency() >= 8
      assert S3.concurrency() <= 32
    end

    # The number is only real if httpc may open that many connections AND does
    # not prefer queueing over opening them. `max_keep_alive_length` is a queue
    # depth per session, not a companion to `max_sessions`: raising it
    # serialises every transfer behind one socket (measured 2.13 s vs 0.09 s).
    # This test exists to stop that being "fixed" back.
    test "httpc may open a session per transfer, and does not queue instead" do
      {:ok, options} = :httpc.get_options([:max_sessions, :max_keep_alive_length])
      assert options[:max_sessions] >= S3.concurrency()
      assert options[:max_keep_alive_length] <= 1
    end
  end

  describe "encode_path/1" do
    # Mix objects are all unreserved, so this must be the identity for them —
    # a change here would silently strand every object already in a store.
    test "leaves an unreserved key exactly as it was" do
      path = "/bucket/v2/jason/1.4.4/e3b0c44298fc1c14.tar.gz"
      assert S3.encode_path(path) == path
    end

    test "leaves the separators alone" do
      assert S3.encode_path("/a/b/c") == "/a/b/c"
    end

    # The defect this fixes. `apt-get install --print-uris` reports a Debian
    # epoch with the colon already percent-encoded, and the apt provider's key
    # IS that filename — so the key holds a literal `%`, which must reach the
    # server as `%25` or the server decodes it back to `:` and canonicalises
    # something the signature never covered.
    test "encodes a literal percent, so an apt epoch survives the round trip" do
      assert S3.encode_path("/b/cpp_4%3a12.2.0-3_amd64.deb") ==
               "/b/cpp_4%253a12.2.0-3_amd64.deb"
    end

    # The second class of key the old code got wrong for the same reason.
    test "encodes a plus" do
      assert S3.encode_path("/b/libx11-6_2%3a1.8.4-2+deb12u2_amd64.deb") ==
               "/b/libx11-6_2%253a1.8.4-2%2Bdeb12u2_amd64.deb"
    end

    test "encodes a colon and a space" do
      assert S3.encode_path("/b/a:b c.deb") == "/b/a%3Ab%20c.deb"
    end
  end

  describe "the requested path" do
    # The invariant: what goes on the wire is what was signed. `request/7`
    # encodes once and hands the SAME string to `sign/5`, so this asserts the
    # observable half — that the URL carries the encoded form — and the other
    # half holds by construction.
    test "is the encoded key, for a name with reserved characters" do
      content = "package bytes"
      path = Path.join(System.tmp_dir!(), "depdep-enc-#{System.unique_integer([:positive])}")
      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)

      object = "apt/v1/debian-trixie/cpp_4%3a12.2.0-3_amd64.deb"
      {port, await} = capture_request(byte_size(content))
      assert S3.put(config(port), object, path) == :ok

      [request_line | _] = String.split(await.(), "\r\n")

      assert request_line ==
               "PUT /bucket/apt/v1/debian-trixie/cpp_4%253a12.2.0-3_amd64.deb HTTP/1.1"
    end

    test "is unchanged for a mix object" do
      content = "archive"
      path = Path.join(System.tmp_dir!(), "depdep-enc2-#{System.unique_integer([:positive])}")
      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)

      object = "v2/jason/1.4.4/e3b0c44298fc1c14.tar.gz"
      {port, await} = capture_request(byte_size(content))
      assert S3.put(config(port), object, path) == :ok

      [request_line | _] = String.split(await.(), "\r\n")
      assert request_line == "PUT /bucket/#{object} HTTP/1.1"
    end
  end
end

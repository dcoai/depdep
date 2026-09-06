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
end

defmodule Depdep.FakeStore do
  @moduledoc """
  A small S3 that answers from a map, for end-to-end tests of a pull or push.

  Speaks just enough HTTP/1.1 for `:httpc`: a request line, headers, a
  `content-length` body, keep-alive. GET streams an object's bytes; HEAD sends
  its size and user metadata as `x-amz-meta-*` headers and no body; PUT
  stores the bytes and the metadata it was sent; anything unknown is 404.

  Accepts any number of connections — a pull runs units concurrently — and
  records every request as `{method, path, headers}` for the test to read
  back with `requests/1`.
  """

  use Agent

  @doc "Starts a store holding `objects` (`%{path => {bytes, metadata}}`); returns `{pid, port}`."
  def start(objects \\ %{}) do
    {:ok, agent} = Agent.start_link(fn -> %{objects: objects, requests: []} end)
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept(listen, agent) end)
    {agent, port}
  end

  def requests(agent), do: Agent.get(agent, & &1.requests) |> Enum.reverse()
  def objects(agent), do: Agent.get(agent, & &1.objects)

  defp accept(listen, agent) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        spawn_link(fn -> serve(sock, agent, "") end)
        accept(listen, agent)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock, agent, buffer) do
    case read_request(sock, buffer) do
      {:ok, method, path, headers, body, rest} ->
        Agent.update(agent, fn s -> %{s | requests: [{method, path, headers} | s.requests]} end)
        :gen_tcp.send(sock, respond(agent, method, path, headers, body))
        serve(sock, agent, rest)

      :closed ->
        :gen_tcp.close(sock)
    end
  end

  defp read_request(sock, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        [request_line | header_lines] = String.split(head, "\r\n")
        [method, target, _] = String.split(request_line, " ", parts: 3)
        headers = Map.new(header_lines, &parse_header/1)
        length = headers |> Map.get("content-length", "0") |> String.to_integer()

        case read_body(sock, rest, length) do
          {:ok, body, rest} -> {:ok, method, path_of(target), headers, body, rest}
          :closed -> :closed
        end

      [_] ->
        case :gen_tcp.recv(sock, 0, 5000) do
          {:ok, chunk} -> read_request(sock, buffer <> chunk)
          {:error, _} -> :closed
        end
    end
  end

  defp read_body(_sock, buffer, length) when byte_size(buffer) >= length do
    <<body::binary-size(^length), rest::binary>> = buffer
    {:ok, body, rest}
  end

  defp read_body(sock, buffer, length) do
    case :gen_tcp.recv(sock, 0, 5000) do
      {:ok, chunk} -> read_body(sock, buffer <> chunk, length)
      {:error, _} -> :closed
    end
  end

  defp parse_header(line) do
    [key, value] = String.split(line, ":", parts: 2)
    {String.downcase(String.trim(key)), String.trim(value)}
  end

  # `/bucket/v2/...` → `v2/...`; a query string is dropped.
  defp path_of(target) do
    target |> String.split("?", parts: 2) |> hd() |> String.split("/", parts: 3) |> List.last()
  end

  defp respond(agent, "PUT", path, headers, body) do
    metadata =
      for {"x-amz-meta-" <> key, value} <- headers, into: %{}, do: {key, value}

    Agent.update(agent, fn s -> %{s | objects: Map.put(s.objects, path, {body, metadata})} end)
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  end

  defp respond(agent, method, path, _headers, _body) when method in ["GET", "HEAD"] do
    case Map.fetch(objects(agent), path) do
      {:ok, {bytes, metadata}} ->
        meta = Enum.map_join(metadata, "", fn {k, v} -> "x-amz-meta-#{k}: #{v}\r\n" end)
        head = "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(bytes)}\r\n#{meta}\r\n"
        if method == "GET", do: head <> bytes, else: head

      :error ->
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
    end
  end

  defp respond(_agent, _method, _path, _headers, _body),
    do: "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n"
end

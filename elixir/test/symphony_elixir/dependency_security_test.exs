defmodule SymphonyElixir.DependencySecurityTest do
  use ExUnit.Case, async: true

  test "Decimal rejects an exponent above its default bound" do
    assert :error == Decimal.parse("1e6145")
    assert :error == Decimal.cast("1e6145")
    assert_raise Decimal.Error, fn -> Decimal.new("1e6145") end
    assert {%Decimal{}, ""} = Decimal.parse("1e6144")
  end

  test "Decimal handles small ordinary values and bounded output" do
    assert 0 == Decimal.to_integer(Decimal.new("0e-2"))
    assert "123" == Decimal.new("000123") |> Decimal.to_string(:normal)
    assert "1.25" == Decimal.to_string(Decimal.add(Decimal.new("1.2"), Decimal.new("0.05")), :normal)

    assert_raise ArgumentError, fn ->
      Decimal.to_string(Decimal.new("123"), :normal, max_digits: 2)
    end
  end

  test "Solid renders a bounded range without changing its output" do
    template = Solid.parse!("{% for i in (1..1000) limit: 3 %}{{ i }} {% endfor %}")
    assert "1 2 3 " == template |> Solid.render!(%{}) |> IO.iodata_to_binary()

    offset = Solid.parse!("{% for i in (1..1000) offset: 5 limit: 2 %}{{ i }} {% endfor %}")
    assert "6 7 " == offset |> Solid.render!(%{}) |> IO.iodata_to_binary()
  end

  test "Solid reports an invalid range limit in returned errors" do
    template = Solid.parse!("{% for i in (1..3) limit: \"bad\" %}{{ i }}{% endfor %}")
    assert {:ok, _rendered, errors} = Solid.render(template, %{}, strict_variables: true)
    assert Enum.any?(errors, &match?(%Solid.ArgumentError{}, &1))
  end

  test "Solid treats whitespace as blank in a template comparison" do
    template = Solid.parse!("{% if value != blank %}filled{% else %}blank{% endif %}")
    assert "blank" == template |> Solid.render!(%{"value" => " "}) |> IO.iodata_to_binary()
    assert "filled" == template |> Solid.render!(%{"value" => "x"}) |> IO.iodata_to_binary()
  end

  test "Req decodes ordinary JSON over a loopback HTTP connection" do
    {url, server} = serve_once(200, ~s({"ok":true}), [{"Content-Type", "application/json"}])

    assert {:ok, %Req.Response{status: 200, body: %{"ok" => true}}} =
             Req.get(url: url, retry: false)

    assert_receive {:request, ^server, request}
    assert request =~ "GET / HTTP/1.1"
  end

  test "Req leaves a compressed JSON response as bytes by default" do
    compressed = :zlib.gzip(~s({"ok":true}))

    {url, _server} =
      serve_once(200, compressed, [
        {"Content-Type", "application/json"},
        {"Content-Encoding", "gzip"}
      ])

    assert {:ok, %Req.Response{status: 200, body: ^compressed}} =
             Req.get(url: url, retry: false)
  end

  test "Req reports invalid gzip when decompression is explicitly enabled" do
    {url, _server} =
      serve_once(200, "not-gzip", [{"Content-Encoding", "gzip"}])

    assert {:error, %Req.DecompressError{format: :gzip}} =
             Req.get(url: url, compressed: true, retry: false)
  end

  test "Req does not follow a redirect when the caller disables it" do
    {target_url, target_server} = serve_once(200, "private", [])
    {source_url, source_server} = serve_once(302, "", [{"Location", target_url}])

    assert {:ok, %Req.Response{status: 302}} =
             Req.get(url: source_url, redirect: false, retry: false)

    assert_receive {:request, ^source_server, _request}
    refute_receive {:request, ^target_server, _request}, 100
  end

  test "Req returns rate limiting as an HTTP response" do
    {url, _server} = serve_once(429, ~s({"error":"rate_limited"}), [{"Content-Type", "application/json"}])

    assert {:ok, %Req.Response{status: 429, body: %{"error" => "rate_limited"}}} =
             Req.get(url: url, retry: false)
  end

  test "Req exits a slow response within its configured receive timeout" do
    {url, _server} = serve_once(200, "late", [], 250)

    assert {:error, %Req.TransportError{}} =
             Req.get(url: url, retry: false, receive_timeout: 50)
  end

  defp serve_once(status, body, headers, delay_ms \\ 0) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn(fn ->
        case :gen_tcp.accept(listener, 3_000) do
          {:ok, socket} ->
            {:ok, request} = :gen_tcp.recv(socket, 0, 3_000)
            send(parent, {:request, self(), request})
            Process.sleep(delay_ms)

            response = [
              "HTTP/1.1 ",
              Integer.to_string(status),
              " ",
              reason(status),
              "\r\n",
              Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
              "Content-Length: ",
              Integer.to_string(byte_size(body)),
              "\r\nConnection: close\r\n\r\n",
              body
            ]

            :gen_tcp.send(socket, response)
            :gen_tcp.close(socket)

          {:error, :closed} ->
            :ok
        end
      end)

    on_exit(fn -> :gen_tcp.close(listener) end)
    {"http://127.0.0.1:#{port}/", server}
  end

  defp reason(200), do: "OK"
  defp reason(302), do: "Found"
  defp reason(429), do: "Too Many Requests"
end

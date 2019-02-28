defmodule TelemetryMetricsStatsdTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  test "counter metric is reported as StatsD counter with 1 as a value" do
    {socket, port} = given_udp_port_opened()
    counter = given_counter("http.requests", event_name: "http.request")

    start_reporter(metrics: [counter], port: port)

    :telemetry.execute([:http, :request], %{latency: 211})
    :telemetry.execute([:http, :request], %{latency: 200})
    :telemetry.execute([:http, :request], %{latency: 198})

    assert_reported(socket, "http.requests:1|c")
    assert_reported(socket, "http.requests:1|c")
    assert_reported(socket, "http.requests:1|c")
  end

  test "sum metric is reported as StatsD gauge with +n value" do
    {socket, port} = given_udp_port_opened()
    sum = given_sum("http.request.payload_size")

    start_reporter(metrics: [sum], port: port)

    :telemetry.execute([:http, :request], %{payload_size: 2001})
    :telemetry.execute([:http, :request], %{payload_size: 1585})
    :telemetry.execute([:http, :request], %{payload_size: 1872})

    assert_reported(socket, "http.request.payload_size:+2001|g")
    assert_reported(socket, "http.request.payload_size:+1585|g")
    assert_reported(socket, "http.request.payload_size:+1872|g")
  end

  test "last value metric is reported as StatsD gauge with absolute value" do
    {socket, port} = given_udp_port_opened()
    last_value = given_last_value("vm.memory.total")

    start_reporter(metrics: [last_value], port: port)

    :telemetry.execute([:vm, :memory], %{total: 2001})
    :telemetry.execute([:vm, :memory], %{total: 1585})
    :telemetry.execute([:vm, :memory], %{total: 1872})

    assert_reported(socket, "vm.memory.total:2001|g")
    assert_reported(socket, "vm.memory.total:1585|g")
    assert_reported(socket, "vm.memory.total:1872|g")
  end

  test "distribution metric is reported as StastD timer" do
    {socket, port} = given_udp_port_opened()

    dist =
      given_distribution("http.request.latency",
        buckets: [0, 100, 200, 300]
      )

    start_reporter(metrics: [dist], port: port)

    :telemetry.execute([:http, :request], %{latency: 172})
    :telemetry.execute([:http, :request], %{latency: 200})
    :telemetry.execute([:http, :request], %{latency: 198})

    assert_reported(socket, "http.request.latency:172|ms")
    assert_reported(socket, "http.request.latency:200|ms")
    assert_reported(socket, "http.request.latency:198|ms")
  end

  test "StatsD metric name is based on metric name and tags" do
    {socket, port} = given_udp_port_opened()

    counter =
      given_counter("http.requests",
        event_name: "http.request",
        metadata: :all,
        tags: [:method, :status]
      )

    start_reporter(metrics: [counter], port: port)

    :telemetry.execute([:http, :request], %{latency: 172}, %{method: "GET", status: 200})
    :telemetry.execute([:http, :request], %{latency: 200}, %{method: "POST", status: 201})
    :telemetry.execute([:http, :request], %{latency: 198}, %{method: "GET", status: 404})

    assert_reported(socket, "http.requests.GET.200:1|c")
    assert_reported(socket, "http.requests.POST.201:1|c")
    assert_reported(socket, "http.requests.GET.404:1|c")
  end

  test "measurement function is taken into account when getting the value for the metric" do
    {socket, port} = given_udp_port_opened()
    last_value = given_last_value("vm.memory.total", measurement: fn m -> m.total * 2 end)

    start_reporter(metrics: [last_value], port: port)

    :telemetry.execute([:vm, :memory], %{total: 2001})
    :telemetry.execute([:vm, :memory], %{total: 1585})
    :telemetry.execute([:vm, :memory], %{total: 1872})

    assert_reported(socket, "vm.memory.total:4002|g")
    assert_reported(socket, "vm.memory.total:3170|g")
    assert_reported(socket, "vm.memory.total:3744|g")
  end

  test "there can be multiple metrics derived from the same event" do
    {socket, port} = given_udp_port_opened()

    dist =
      given_distribution("http.request.latency",
        buckets: [0, 100, 200, 300]
      )

    sum = given_sum("http.request.payload_size")

    start_reporter(metrics: [dist, sum], port: port)

    :telemetry.execute([:http, :request], %{latency: 172, payload_size: 121})
    :telemetry.execute([:http, :request], %{latency: 200, payload_size: 64})
    :telemetry.execute([:http, :request], %{latency: 198, payload_size: 1021})

    assert_reported(
      socket,
      "http.request.latency:172|ms\n" <>
        "http.request.payload_size:+121|g"
    )

    assert_reported(
      socket,
      "http.request.latency:200|ms\n" <>
        "http.request.payload_size:+64|g"
    )

    assert_reported(
      socket,
      "http.request.latency:198|ms\n" <>
        "http.request.payload_size:+1021|g"
    )
  end

  describe "UDP error handling" do
    @tag :error_handling
    test "notifying a UDP error logs an error" do
      reporter = start_reporter(metrics: [])
      udp = TelemetryMetricsStatsd.get_udp(reporter)

      assert capture_log(fn ->
               TelemetryMetricsStatsd.udp_error(reporter, udp, :closed)
               # Can we do better here? We could use `call` instead of `cast` for reporting socket
               # errors.
               Process.sleep(100)
             end) =~ ~r/\[error\] Failed to publish metrics over UDP: :closed/
    end

    test "notifying a UDP error for the same socket multiple times generates only one log" do
      reporter = start_reporter(metrics: [])
      udp = TelemetryMetricsStatsd.get_udp(reporter)

      assert capture_log(fn ->
               TelemetryMetricsStatsd.udp_error(reporter, udp, :closed)
               Process.sleep(100)
             end) =~ ~r/\[error\] Failed to publish metrics over UDP: :closed/

      refute capture_log(fn ->
               TelemetryMetricsStatsd.udp_error(reporter, udp, :closed)
               Process.sleep(100)
             end) == ""
    end

    @tag :capture_log
    test "notifying a UDP error and fetching a socket returns a new socket" do
      reporter = start_reporter(metrics: [])
      udp = TelemetryMetricsStatsd.get_udp(reporter)

      TelemetryMetricsStatsd.udp_error(reporter, udp, :closed)
      new_udp = TelemetryMetricsStatsd.get_udp(reporter)

      assert new_udp != udp
    end
  end

  defp given_udp_port_opened() do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    {socket, port}
  end

  defp given_counter(event_name, opts \\ []) do
    Telemetry.Metrics.counter(event_name, opts)
  end

  defp given_sum(event_name, opts \\ []) do
    Telemetry.Metrics.sum(event_name, opts)
  end

  defp given_last_value(event_name, opts \\ []) do
    Telemetry.Metrics.last_value(event_name, opts)
  end

  defp given_distribution(event_name, opts \\ []) do
    Telemetry.Metrics.distribution(event_name, opts)
  end

  defp start_reporter(options) do
    start_supervised!({TelemetryMetricsStatsd, options})
  end

  defp assert_reported(socket, expected_payload) do
    expected_size = byte_size(expected_payload)
    {:ok, {_host, _port, payload}} = :gen_udp.recv(socket, expected_size)
    assert payload == expected_payload
  end
end
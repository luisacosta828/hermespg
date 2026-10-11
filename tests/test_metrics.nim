import std/[unittest, asyncnet, asyncdispatch, strutils, httpclient]
import hermespg/metrics

suite "HermesPG Metrics & OpenMetrics Exporter":
  test "Atomic metrics counters and gauges behave correctly":
    initMetrics(maxConns = 32, maxQueue = 1000, workers = 4)
    check mMaxConnections.getMetric() == 32
    check mMaxQueueSize.getMetric() == 1000
    check mWorkersCount.getMetric() == 4

    mActiveConnections.setMetric(5)
    check mActiveConnections.getMetric() == 5
    mActiveConnections.incMetric(3)
    check mActiveConnections.getMetric() == 8
    mActiveConnections.decMetric(2)
    check mActiveConnections.getMetric() == 6

    mTransactionsTotal.setMetric(0)
    mTransactionsTotal.incMetric()
    mTransactionsTotal.incMetric(10)
    check mTransactionsTotal.getMetric() == 11

    mAuthFailuresInvalidPass.setMetric(2)
    mAuthFailuresInvalidUser.setMetric(1)
    check mAuthFailuresInvalidPass.getMetric() == 2
    check mAuthFailuresInvalidUser.getMetric() == 1

  test "generateOpenMetrics outputs compliant OpenMetrics payload":
    initMetrics(maxConns = 25, maxQueue = 500, workers = 2)
    mActiveConnections.setMetric(10)
    mIdleConnections.setMetric(15)
    mTransactionsTotal.setMetric(142000)
    mQueriesTotal.setMetric(284000)
    mAuthFailuresInvalidPass.setMetric(3)

    let payload = generateOpenMetrics()
    check payload.contains("# HELP hermespg_pool_active_connections")
    check payload.contains("# TYPE hermespg_pool_active_connections gauge")
    check payload.contains("hermespg_pool_active_connections 10")
    check payload.contains("hermespg_pool_idle_connections 15")
    check payload.contains("hermespg_transactions_total 142000")
    check payload.contains("hermespg_queries_total 284000")
    check payload.contains("hermespg_auth_failures_total{reason=\"invalid_password\"} 3")
    check payload.contains("hermespg_uptime_seconds")

  test "HTTP exporter serves /metrics endpoint asynchronously":
    let testPort = Port(19127)
    asyncCheck startMetricsServer(testPort, "127.0.0.1")

    proc testFetch(): Future[void] {.async.} =
      await sleepAsync(50)
      let client = newAsyncHttpClient()
      defer: client.close()
      let resp = await client.getContent("http://127.0.0.1:19127/metrics")
      check resp.contains("hermespg_pool_active_connections")
      check resp.contains("hermespg_uptime_seconds")

    waitFor testFetch()

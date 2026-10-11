## Module: hermespg/metrics
## High-performance, zero-allocation Prometheus and OpenMetrics exporter for HermesPG
import std/[atomics, strutils, strformat, asyncnet, asyncdispatch, times]

var
  # Gauges
  mActiveConnections*: Atomic[int]
  mIdleConnections*: Atomic[int]
  mMaxConnections*: Atomic[int]
  mWaitingClients*: Atomic[int]
  mMaxQueueSize*: Atomic[int]
  mConnectedClients*: Atomic[int]
  mWorkersCount*: Atomic[int]

  # Counters
  mClientsTotal*: Atomic[int]
  mTransactionsTotal*: Atomic[int]
  mQueriesTotal*: Atomic[int]
  mAcquireTotal*: Atomic[int]
  mAcquireFastPathTotal*: Atomic[int]
  mAcquireSlowPathTotal*: Atomic[int]
  mSheddedRequestsTotal*: Atomic[int]
  mQueueTimeoutsTotal*: Atomic[int]
  mAuthAttemptsTotal*: Atomic[int]
  mAuthSuccessTotal*: Atomic[int]
  mAuthFailuresInvalidPass*: Atomic[int]
  mAuthFailuresInvalidUser*: Atomic[int]
  mIdleTxRollbacksTotal*: Atomic[int]
  mDirtyResetsTotal*: Atomic[int]

  mStartTime*: float

proc initMetrics*(maxConns, maxQueue, workers: int) =
  mMaxConnections.store(maxConns)
  mMaxQueueSize.store(maxQueue)
  mWorkersCount.store(workers)
  mStartTime = epochTime()

proc incMetric*(a: var Atomic[int], delta = 1) {.inline.} =
  discard a.fetchAdd(delta)

proc decMetric*(a: var Atomic[int], delta = 1) {.inline.} =
  discard a.fetchSub(delta)

proc setMetric*(a: var Atomic[int], val: int) {.inline.} =
  a.store(val)

proc getMetric*(a: var Atomic[int]): int {.inline.} =
  a.load()

proc generateOpenMetrics*(): string =
  var res = newStringOfCap(4096)
  let uptime = epochTime() - mStartTime

  res.add("# HELP hermespg_pool_active_connections Currently leased backend connections\n")
  res.add("# TYPE hermespg_pool_active_connections gauge\n")
  res.add("hermespg_pool_active_connections " & $mActiveConnections.load() & "\n")

  res.add("# HELP hermespg_pool_idle_connections Currently available idle backend connections\n")
  res.add("# TYPE hermespg_pool_idle_connections gauge\n")
  res.add("hermespg_pool_idle_connections " & $mIdleConnections.load() & "\n")

  res.add("# HELP hermespg_pool_max_connections Maximum physical backend capacity configured\n")
  res.add("# TYPE hermespg_pool_max_connections gauge\n")
  res.add("hermespg_pool_max_connections " & $mMaxConnections.load() & "\n")

  res.add("# HELP hermespg_pool_acquire_total Total connection acquisitions\n")
  res.add("# TYPE hermespg_pool_acquire_total counter\n")
  res.add("hermespg_pool_acquire_total " & $mAcquireTotal.load() & "\n")

  res.add("# HELP hermespg_pool_acquire_fast_path_total Acquisitions resolved synchronously via stack fast-path\n")
  res.add("# TYPE hermespg_pool_acquire_fast_path_total counter\n")
  res.add("hermespg_pool_acquire_fast_path_total " & $mAcquireFastPathTotal.load() & "\n")

  res.add("# HELP hermespg_pool_acquire_slow_path_total Acquisitions resolved asynchronously via wait queue\n")
  res.add("# TYPE hermespg_pool_acquire_slow_path_total counter\n")
  res.add("hermespg_pool_acquire_slow_path_total " & $mAcquireSlowPathTotal.load() & "\n")

  res.add("# HELP hermespg_connected_clients Active frontend client connections\n")
  res.add("# TYPE hermespg_connected_clients gauge\n")
  res.add("hermespg_connected_clients " & $mConnectedClients.load() & "\n")

  res.add("# HELP hermespg_clients_total Total client connections accepted\n")
  res.add("# TYPE hermespg_clients_total counter\n")
  res.add("hermespg_clients_total " & $mClientsTotal.load() & "\n")

  res.add("# HELP hermespg_transactions_total Total transactions completed\n")
  res.add("# TYPE hermespg_transactions_total counter\n")
  res.add("hermespg_transactions_total " & $mTransactionsTotal.load() & "\n")

  res.add("# HELP hermespg_queries_total Total query packets processed\n")
  res.add("# TYPE hermespg_queries_total counter\n")
  res.add("hermespg_queries_total " & $mQueriesTotal.load() & "\n")

  res.add("# HELP hermespg_queue_waiting_clients Clients currently queued waiting for connection\n")
  res.add("# TYPE hermespg_queue_waiting_clients gauge\n")
  res.add("hermespg_queue_waiting_clients " & $mWaitingClients.load() & "\n")

  res.add("# HELP hermespg_queue_max_size Configured queue capacity limit before load shedding\n")
  res.add("# TYPE hermespg_queue_max_size gauge\n")
  res.add("hermespg_queue_max_size " & $mMaxQueueSize.load() & "\n")

  res.add("# HELP hermespg_shedded_requests_total Requests rejected immediately due to queue saturation (SQLSTATE 53300)\n")
  res.add("# TYPE hermespg_shedded_requests_total counter\n")
  res.add("hermespg_shedded_requests_total " & $mSheddedRequestsTotal.load() & "\n")

  res.add("# HELP hermespg_queue_timeouts_total Client requests timed out waiting in queue\n")
  res.add("# TYPE hermespg_queue_timeouts_total counter\n")
  res.add("hermespg_queue_timeouts_total " & $mQueueTimeoutsTotal.load() & "\n")

  res.add("# HELP hermespg_auth_attempts_total Total authentication attempts\n")
  res.add("# TYPE hermespg_auth_attempts_total counter\n")
  res.add("hermespg_auth_attempts_total " & $mAuthAttemptsTotal.load() & "\n")

  res.add("# HELP hermespg_auth_success_total Successful SCRAM-SHA-256 authentications\n")
  res.add("# TYPE hermespg_auth_success_total counter\n")
  res.add("hermespg_auth_success_total " & $mAuthSuccessTotal.load() & "\n")

  res.add("# HELP hermespg_auth_failures_total Total failed authentication attempts (SQLSTATE 28P01)\n")
  res.add("# TYPE hermespg_auth_failures_total counter\n")
  res.add("hermespg_auth_failures_total{reason=\"invalid_password\"} " & $mAuthFailuresInvalidPass.load() & "\n")
  res.add("hermespg_auth_failures_total{reason=\"invalid_user\"} " & $mAuthFailuresInvalidUser.load() & "\n")

  res.add("# HELP hermespg_idle_tx_rollbacks_total Rogue abandoned transactions forced to ROLLBACK by watchdog\n")
  res.add("# TYPE hermespg_idle_tx_rollbacks_total counter\n")
  res.add("hermespg_idle_tx_rollbacks_total " & $mIdleTxRollbacksTotal.load() & "\n")

  res.add("# HELP hermespg_dirty_resets_total Mutated connections cleaned with DISCARD ALL before reuse\n")
  res.add("# TYPE hermespg_dirty_resets_total counter\n")
  res.add("hermespg_dirty_resets_total " & $mDirtyResetsTotal.load() & "\n")

  res.add("# HELP hermespg_uptime_seconds Seconds since server started\n")
  res.add("# TYPE hermespg_uptime_seconds counter\n")
  res.add("hermespg_uptime_seconds " & $int(uptime) & "\n")

  res.add("# HELP hermespg_workers_count Number of worker threads\n")
  res.add("# TYPE hermespg_workers_count gauge\n")
  res.add("hermespg_workers_count " & $mWorkersCount.load() & "\n")

  return res

proc handleMetricsClient(client: AsyncSocket) {.async.} =
  try:
    let req = await client.recv(1024)
    if req.len > 0 and (req.startsWith("GET /metrics") or req.startsWith("GET / ") or req.startsWith("GET /metrics ")):
      let body = generateOpenMetrics()
      let resp = "HTTP/1.1 200 OK\r\n" &
                 "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n" &
                 "Content-Length: " & $body.len & "\r\n" &
                 "Connection: close\r\n\r\n" & body
      await client.send(resp)
    else:
      let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      await client.send(notFound)
  except CatchableError:
    discard
  finally:
    client.close()

proc startMetricsServer*(port: Port, bindAddr = "0.0.0.0") {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  if bindAddr.len > 0 and bindAddr != "0.0.0.0":
    server.bindAddr(port, bindAddr)
  else:
    server.bindAddr(port)
  server.listen(128)
  let display = if bindAddr.len > 0: bindAddr else: "0.0.0.0"
  echo fmt"[*] Prometheus metrics exporter listening on http://{display}:{port.int}/metrics"
  while true:
    let client = await server.accept()
    asyncCheck handleMetricsClient(client)

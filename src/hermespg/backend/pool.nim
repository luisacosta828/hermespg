## Connection Pool Manager with bounded O(1) wait queues, Load Shedding, and Fail-Fast flow
import std/[asyncnet, asyncdispatch, strformat, deques, monotimes, times]
import ../protocol/messages
import ./connection

type
  AcquireStatus* = enum
    AcquireOk
    AcquireTimeout
    AcquireQueueFull
    AcquireShuttingDown
    AcquireFailed

  AcquireResult* = object
    status*: AcquireStatus
    conn*: BackendConn
    errorMsg*: string

  PoolSettings* = object
    pgHost*: string
    pgPort*: Port
    user*: string
    password*: string
    database*: string
    maxConnections*: int
    maxQueueSize*: int              ## Max clients waiting in queue before immediate Load Shedding
    acquireTimeoutMs*: int
    idleTxTimeoutMs*: int           ## Max idle time for an in-progress transaction before forcing ROLLBACK
    resetQuery*: string             ## Session cleanup query (e.g. "DISCARD ALL;")
    resetBeforeFirstQuery*: bool    ## Whether to sanitize dirty connection before leasing

  PendingClient* = ref object
    fut*: Future[BackendConn]
    deadline*: MonoTime

  ConnectionPool* = ref object
    settings*: PoolSettings
    idleConns*: seq[BackendConn]
    activeCount*: int
    waitQueue*: Deque[PendingClient]
    isShuttingDown*: bool
    nextConnId*: int
    watchdogRunning*: bool

proc checkTimeouts(pool: ConnectionPool) =
  let now = getMonoTime()
  while pool.waitQueue.len > 0:
    let first = pool.waitQueue.peekFirst()
    if now >= first.deadline:
      let client = pool.waitQueue.popFirst()
      if not client.fut.finished:
        client.fut.complete(nil)
    else:
      break

proc startWatchdog(pool: ConnectionPool) =
  if pool.watchdogRunning: return
  pool.watchdogRunning = true
  asyncCheck (proc() {.async.} =
    while not pool.isShuttingDown:
      await sleepAsync(50)
      pool.checkTimeouts()
    pool.watchdogRunning = false
  )()

proc newConnectionPool*(settings: PoolSettings): ConnectionPool =
  result = ConnectionPool(
    settings: settings,
    idleConns: @[],
    activeCount: 0,
    waitQueue: initDeque[PendingClient](),
    isShuttingDown: false,
    nextConnId: 1,
    watchdogRunning: false
  )
  result.startWatchdog()

proc prewarm*(pool: ConnectionPool): Future[void] {.async.} =
  ## Pre-establishes all configured backend connections to PostgreSQL up-front.
  ## Eliminates connection creation latency during initial client surges.
  while pool.activeCount < pool.settings.maxConnections:
    let connId = pool.nextConnId
    inc pool.nextConnId
    inc pool.activeCount
    try:
      let conn = await connectBackend(
        pool.settings.pgHost,
        pool.settings.pgPort,
        pool.settings.user,
        pool.settings.password,
        pool.settings.database,
        connId
      )
      pool.idleConns.add(conn)
    except CatchableError as e:
      dec pool.activeCount
      raise e

proc tryAcquireFast*(pool: ConnectionPool, conn: var BackendConn): bool {.inline.} =
  ## Zero-allocation synchronous acquisition fast path when an idle clean connection is ready.
  ## Avoids Future[AcquireResult] allocation and async event loop hops on cache hit.
  if pool.isShuttingDown:
    return false

  while pool.idleConns.len > 0:
    let c = pool.idleConns.pop()
    if c.isAlive and not c.socket.isClosed and not c.isDirty:
      conn = c
      return true
    else:
      dec pool.activeCount

  return false

proc acquire*(pool: ConnectionPool): Future[AcquireResult] {.async.} =
  if pool.isShuttingDown:
    return AcquireResult(status: AcquireShuttingDown, conn: nil)

  # 1. Reuse available idle connection
  while pool.idleConns.len > 0:
    let conn = pool.idleConns.pop()
    if conn.isAlive and not conn.socket.isClosed:
      if pool.settings.resetBeforeFirstQuery and conn.isDirty and pool.settings.resetQuery.len > 0:
        let ok = await conn.executeSimple(pool.settings.resetQuery)
        if not ok:
          await conn.terminate()
          dec pool.activeCount
          continue
        conn.isDirty = false

      return AcquireResult(status: AcquireOk, conn: conn)
    else:
      dec pool.activeCount

  # 2. Open new physical connection if capacity permits
  if pool.activeCount < pool.settings.maxConnections:
    inc pool.activeCount
    let connId = pool.nextConnId
    inc pool.nextConnId
    try:
      let conn = await connectBackend(
        pool.settings.pgHost,
        pool.settings.pgPort,
        pool.settings.user,
        pool.settings.password,
        pool.settings.database,
        connId
      )
      return AcquireResult(status: AcquireOk, conn: conn)
    except CatchableError as e:
      dec pool.activeCount
      return AcquireResult(status: AcquireFailed, conn: nil, errorMsg: e.msg)

  # 3. Fail-Fast overload protection (O(1) Load Shedding)
  if pool.waitQueue.len >= pool.settings.maxQueueSize:
    return AcquireResult(status: AcquireQueueFull, conn: nil)

  # 4. Enqueue in O(1) deque with monotonic deadline
  let deadline = getMonoTime() + initDuration(milliseconds = pool.settings.acquireTimeoutMs)
  let pending = PendingClient(
    fut: newFuture[BackendConn]("acquire.wait"),
    deadline: deadline
  )
  pool.waitQueue.addLast(pending)

  let conn = await pending.fut
  if conn == nil:
    if pool.isShuttingDown:
      return AcquireResult(status: AcquireShuttingDown, conn: nil)
    return AcquireResult(status: AcquireTimeout, conn: nil)

  return AcquireResult(status: AcquireOk, conn: conn)

proc releaseFast*(pool: ConnectionPool, conn: BackendConn) {.inline.} =
  ## Zero-allocation synchronous release fast path for idle clean connections.
  ## Avoids Future[void] allocation and dispatcher ticks when no cleanup/queuing is pending.
  if conn == nil or not conn.isAlive or conn.socket.isClosed:
    return

  let now = getMonoTime()
  while pool.waitQueue.len > 0:
    let nextClient = pool.waitQueue.popFirst()
    if not nextClient.fut.finished:
      if now > nextClient.deadline:
        nextClient.fut.complete(nil)
        continue
      nextClient.fut.complete(conn)
      return

  pool.idleConns.add(conn)

proc release*(pool: ConnectionPool, conn: BackendConn, dirty = false) {.async.} =
  if conn == nil:
    return

  if not conn.isAlive or conn.socket.isClosed:
    dec pool.activeCount
    if pool.waitQueue.len > 0 and not pool.isShuttingDown:
      asyncCheck (proc() {.async.} =
        let acq = await pool.acquire()
        if acq.status == AcquireOk:
          await pool.release(acq.conn, false)
      )()
    return

  conn.isDirty = conn.isDirty or dirty

  if conn.lastStatus != Idle:
    discard await conn.executeSimple("ROLLBACK;")
    conn.isDirty = true

  if pool.isShuttingDown:
    await conn.terminate()
    dec pool.activeCount
    return

  # Dispatch directly to next waiting client in O(1)
  let now = getMonoTime()
  while pool.waitQueue.len > 0:
    let nextClient = pool.waitQueue.popFirst()
    if not nextClient.fut.finished:
      if now > nextClient.deadline:
        nextClient.fut.complete(nil)
        continue
      if pool.settings.resetBeforeFirstQuery and conn.isDirty and pool.settings.resetQuery.len > 0:
        discard await conn.executeSimple(pool.settings.resetQuery)
        conn.isDirty = false
      nextClient.fut.complete(conn)
      return

  pool.idleConns.add(conn)

proc shutdown*(pool: ConnectionPool, graceTimeoutMs = 5000): Future[void] {.async.} =
  pool.isShuttingDown = true

  while pool.waitQueue.len > 0:
    let pending = pool.waitQueue.popFirst()
    if not pending.fut.finished:
      pending.fut.complete(nil)

  for conn in pool.idleConns:
    await conn.terminate()
    dec pool.activeCount
  pool.idleConns.setLen(0)

  let checkInterval = 50
  var waited = 0
  while pool.activeCount > 0 and waited < graceTimeoutMs:
    await sleepAsync(checkInterval)
    waited.inc(checkInterval)

  echo fmt"[POOL] Shutdown completed. Remaining active connections: {pool.activeCount}"

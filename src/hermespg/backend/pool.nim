## Gestor del Pool de Conexiones Backend con soporte para colas acotadas O(1), Load Shedding y Zero-Exception flow
import std/[asyncnet, asyncdispatch, strformat, deques]
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
    maxQueueSize*: int              ## Límite de clientes esperando en cola (Load Shedding)
    acquireTimeoutMs*: int
    idleTxTimeoutMs*: int           ## Tiempo máximo de una transacción inactiva antes de forzar ROLLBACK
    resetQuery*: string             ## Consulta de limpieza (ej. "DISCARD ALL;")
    resetBeforeFirstQuery*: bool    ## Si debe limpiarse antes de prestarla

  PendingClient* = ref object
    fut*: Future[BackendConn]
    isCancelled*: bool

  ConnectionPool* = ref object
    settings*: PoolSettings
    idleConns*: seq[BackendConn]
    activeCount*: int
    waitQueue*: Deque[PendingClient]
    isShuttingDown*: bool
    nextConnId*: int

proc newConnectionPool*(settings: PoolSettings): ConnectionPool =
  ConnectionPool(
    settings: settings,
    idleConns: @[],
    activeCount: 0,
    waitQueue: initDeque[PendingClient](),
    isShuttingDown: false,
    nextConnId: 1
  )

proc acquire*(pool: ConnectionPool): Future[AcquireResult] {.async.} =
  if pool.isShuttingDown:
    return AcquireResult(status: AcquireShuttingDown, conn: nil)

  # 1. Reutilizar conexión en idle
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

  # 2. Abrir nueva conexión física si hay cupo
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

  # 3. Control de sobrecarga Fail-Fast (Load Shedding en O(1))
  if pool.waitQueue.len >= pool.settings.maxQueueSize:
    return AcquireResult(status: AcquireQueueFull, conn: nil)

  # 4. Encolar en deque O(1) con timeout
  let pending = PendingClient(
    fut: newFuture[BackendConn]("acquire.wait"),
    isCancelled: false
  )
  pool.waitQueue.addLast(pending)

  let completed = await withTimeout(pending.fut, pool.settings.acquireTimeoutMs)
  if not completed:
    pending.isCancelled = true
    return AcquireResult(status: AcquireTimeout, conn: nil)

  if pending.fut.failed:
    return AcquireResult(status: AcquireShuttingDown, conn: nil)

  return AcquireResult(status: AcquireOk, conn: pending.fut.read())

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

  # Buscar el siguiente cliente esperando en O(1)
  while pool.waitQueue.len > 0:
    let nextClient = pool.waitQueue.popFirst()
    if not nextClient.isCancelled and not nextClient.fut.finished:
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
      pending.isCancelled = true
      pending.fut.fail(newException(IOError, "El pool fue cerrado"))

  for conn in pool.idleConns:
    await conn.terminate()
    dec pool.activeCount
  pool.idleConns.setLen(0)

  let checkInterval = 50
  var waited = 0
  while pool.activeCount > 0 and waited < graceTimeoutMs:
    await sleepAsync(checkInterval)
    waited.inc(checkInterval)

  echo fmt"[POOL] Apagado finalizado. Conexiones activas restantes: {pool.activeCount}"

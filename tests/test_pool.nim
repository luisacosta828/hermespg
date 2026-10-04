import std/[unittest, asyncdispatch]
import hermespg/protocol/messages
import hermespg/backend/[connection, pool]

suite "Connection Pool and State Cleanup":
  test "Pool can acquire, reset state, and release backend connections":
    let settings = PoolSettings(
      pgHost: "127.0.0.1",
      pgPort: Port(5432),
      user: "postgres",
      password: "",
      database: "postgres",
      maxConnections: 2,
      maxQueueSize: 10,
      acquireTimeoutMs: 2000,
      idleTxTimeoutMs: 5000,
      resetQuery: "DISCARD ALL;",
      resetBeforeFirstQuery: true
    )

    let p = newConnectionPool(settings)

    waitFor (proc() {.async.} =
      # 1. Adquirir primera conexión
      let acq1 = await p.acquire()
      check acq1.status == AcquireOk
      let conn1 = acq1.conn
      check conn1 != nil
      check conn1.isAlive
      check p.activeCount == 1

      # 2. Modificar el estado de la sesión (SET search_path)
      let setOk = await conn1.executeSimple("SET search_path = my_custom_schema;")
      check setOk

      # 3. Devolverla al pool marcada como sucia (dirty = true)
      await p.release(conn1, dirty = true)
      check p.idleConns.len == 1

      # 4. Volver a adquirir la conexión (debe ejecutar DISCARD ALL antes de entregarla)
      let acq2 = await p.acquire()
      check acq2.status == AcquireOk
      let conn2 = acq2.conn
      check conn2.id == conn1.id # Reutilizó la misma conexión física
      check not conn2.isDirty     # Fue limpiada exitosamente

      # 5. Liberar y probar shutdown graceful
      await p.release(conn2)
      check p.idleConns.len == 1

      await p.shutdown(graceTimeoutMs = 1000)
      check p.idleConns.len == 0
      check p.activeCount == 0
    )()

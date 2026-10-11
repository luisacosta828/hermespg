import std/[asyncdispatch, unittest]
import hermespg/backend/connection

suite "Live PostgreSQL SCRAM-SHA-256 Authentication":
  test "Connect successfully using valid SCRAM credentials":
    let conn = waitFor connectBackend(
      host = "127.0.0.1",
      port = Port(5432),
      user = "scram_user",
      password = "HermesSecr3t!2026",
      database = "postgres",
      connId = 1
    )
    check conn != nil
    check conn.isAlive == true
    check conn.backendPid > 0
    echo "[*] Connected with SCRAM-SHA-256! Backend PID: ", conn.backendPid
    waitFor conn.terminate()

  test "Fail connection when invalid password is provided":
    var failed = false
    try:
      let badConn = waitFor connectBackend(
        host = "127.0.0.1",
        port = Port(5432),
        user = "scram_user",
        password = "WrongPassword!",
        database = "postgres",
        connId = 2
      )
      waitFor badConn.terminate()
    except IOError:
      failed = true
    check failed == true

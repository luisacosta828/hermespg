import std/[unittest, asyncdispatch, os, nativesockets]
import hermespg/backend/[connection, pool]
import hermespg/crypto/scram
import hermespg/proxy

suite "HermesPG Gateway Mode (Multi-Tenant Authentication & Role Dispatching)":
  test "Gateway multi-user authentication, rejection, and role isolation":
    let tmpDir = getTempDir()
    let authPath = tmpDir / "test_gateway_userlist.txt"

    # Alice has plaintext password, Bob has pre-hashed SCRAM verifier
    let bobVerifier = generateVerifier("BobSecret!2026")
    let bobScramStr = formatScramSecret(bobVerifier)
    let authContent = "# Gateway Mode Test Credentials\n" &
      "\"hermes_alice\" \"AliceSecret!2026\"\n" &
      "\"hermes_bob\" \"" & bobScramStr & "\"\n"
    writeFile(authPath, authContent)

    let testPort = Port(6435)
    let poolSettings = PoolSettings(
      pgHost: "127.0.0.1",
      pgPort: Port(5432),
      user: "postgres",
      password: "",
      database: "postgres",
      maxConnections: 2,
      maxQueueSize: 20,
      acquireTimeoutMs: 5000,
      idleTxTimeoutMs: 5000,
      resetQuery: "DISCARD ALL;",
      resetBeforeFirstQuery: true
    )

    let srvConfig = ServerConfig(
      listenAddress: "127.0.0.1",
      listenPort: testPort,
      poolSettings: poolSettings,
      verbose: false,
      mode: ModeGateway,
      authFile: authPath
    )

    waitFor (proc() {.async.} =
      # 1. Start HermesPG in Gateway mode
      let srvFut = startServer(srvConfig)
      await sleepAsync(200) # Wait for server listener to bind

      # 2. Authenticate as hermes_alice (plaintext password in authfile)
      let connAlice = await connectBackend(
        host = "127.0.0.1",
        port = testPort,
        user = "hermes_alice",
        password = "AliceSecret!2026",
        database = "postgres",
        connId = 101
      )
      check connAlice != nil
      check connAlice.isAlive == true
      let okAlice = await connAlice.executeSimple("SELECT current_user;")
      check okAlice == true

      # Create a temporary table in Alice's session 1
      let okTemp = await connAlice.executeSimple("CREATE TEMP TABLE t_alice_leak(val int);")
      check okTemp == true

      # Session affinity check: Consecutive queries within SAME session preserve temp table
      let sameSessionCheck = await connAlice.executeSimple("SELECT * FROM t_alice_leak;")
      check sameSessionCheck == true

      # 3. Authenticate as hermes_bob while Alice is STILL CONNECTED (concurrent tenants)
      let connBob = await connectBackend(
        host = "127.0.0.1",
        port = testPort,
        user = "hermes_bob",
        password = "BobSecret!2026",
        database = "postgres",
        connId = 102
      )
      check connBob != nil
      check connBob.isAlive == true
      let okBob = await connBob.executeSimple("SELECT current_user;")
      check okBob == true

      # Verify cross-tenant isolation: Bob cannot see Alice's temporary table
      let bobLeakCheck = await connBob.executeSimple("SELECT * FROM t_alice_leak;")
      check bobLeakCheck == false
      await connBob.terminate()

      # 4. Same-User Multi-Session Isolation: Alice opens Session 2 while Session 1 is active
      let connAlice2 = await connectBackend(
        host = "127.0.0.1",
        port = testPort,
        user = "hermes_alice",
        password = "AliceSecret!2026",
        database = "postgres",
        connId = 105
      )
      check connAlice2 != nil
      check connAlice2.isAlive == true
      # Alice Session 2 must NOT see Alice Session 1's temporary table!
      let alice2LeakCheck = await connAlice2.executeSimple("SELECT * FROM t_alice_leak;")
      check alice2LeakCheck == false

      # Create temp table in Alice Session 2
      let okAlice2Temp = await connAlice2.executeSimple("CREATE TEMP TABLE t_alice_session2(val int);")
      check okAlice2Temp == true

      # Disconnect Alice Session 1 and Session 2
      await connAlice.terminate()
      await connAlice2.terminate()
      await sleepAsync(50) # Allow server disconnect finally block to run

      # 5. Post-Disconnect Hygiene: Alice opens Session 3 after previous sessions disconnected
      let connAlice3 = await connectBackend(
        host = "127.0.0.1",
        port = testPort,
        user = "hermes_alice",
        password = "AliceSecret!2026",
        database = "postgres",
        connId = 106
      )
      check connAlice3 != nil
      check connAlice3.isAlive == true
      # None of the previous sessions' temporary tables should linger
      let leakCheckAfterDisc1 = await connAlice3.executeSimple("SELECT * FROM t_alice_leak;")
      check leakCheckAfterDisc1 == false
      let leakCheckAfterDisc2 = await connAlice3.executeSimple("SELECT * FROM t_alice_session2;")
      check leakCheckAfterDisc2 == false
      await connAlice3.terminate()

      # 6. Authentication Failure: Wrong password for valid user
      var badPassFailed = false
      try:
        let badConn = await connectBackend(
          host = "127.0.0.1",
          port = testPort,
          user = "hermes_alice",
          password = "WrongPassword!999",
          database = "postgres",
          connId = 103
        )
        await badConn.terminate()
      except IOError:
        badPassFailed = true
      check badPassFailed == true

      # 7. Authentication Failure: Unknown tenant user not in userlist
      var unknownUserFailed = false
      try:
        let intruderConn = await connectBackend(
          host = "127.0.0.1",
          port = testPort,
          user = "unknown_intruder",
          password = "AnyPassword",
          database = "postgres",
          connId = 104
        )
        await intruderConn.terminate()
      except IOError:
        unknownUserFailed = true
      check unknownUserFailed == true

      # 8. Clean shutdown of proxy server
      shutdownRequested = true
      if shutdownFuture != nil and not shutdownFuture.finished:
        shutdownFuture.complete()
      await srvFut
    )()

    # Cleanup temp auth file
    if fileExists(authPath):
      removeFile(authPath)

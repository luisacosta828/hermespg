import std/[unittest, os, strutils, asyncdispatch, nativesockets]
when defined(posix):
  import std/posix
import hermespg/auth/catalog
import hermespg/crypto/scram
import hermespg/backend/connection

suite "HermesPG User Catalog & Identifier Quoting":
  test "Identifier quoting and validation":
    check isValidIdentifier("alice") == true
    check isValidIdentifier("_bob123") == true
    check isValidIdentifier("123bad") == false
    check isValidIdentifier("user-name") == false
    check isValidIdentifier("user;drop table") == false
    check isValidIdentifier("") == false

    check quoteIdentifier("alice") == "\"alice\""
    check quoteIdentifier("alice\"test") == "\"alice\"\"test\""
    check quoteIdentifier("User With Space") == "\"User With Space\""

    expect ValueError:
      discard quoteIdentifier("bad\0user")
    expect ValueError:
      discard quoteIdentifier("")

  test "Parse auth file lines":
    var user, secret: string

    # PgBouncer standard quoted format
    check parseAuthLine("\"alice\" \"secret123\"", user, secret) == true
    check user == "alice"
    check secret == "secret123"

    # Colon format
    check parseAuthLine("bob:secret456", user, secret) == true
    check user == "bob"
    check secret == "secret456"

    # Space separated
    check parseAuthLine("carol pass789", user, secret) == true
    check user == "carol"
    check secret == "pass789"

    # Comments and empty lines
    check parseAuthLine("# comment line", user, secret) == false
    check parseAuthLine("   ; another comment", user, secret) == false
    check parseAuthLine("   \t  ", user, secret) == false

  test "Zero secret leakage in parse errors":
    var user, secret: string

    # Unterminated password quote must NOT include the secret in the exception message
    var caughtMsg = ""
    try:
      discard parseAuthLine("\"alice\" \"TopSecretPasswordNeverLeak", user, secret, lineNum = 7)
    except ValueError as e:
      caughtMsg = e.msg
    check caughtMsg.len > 0
    check "line #7" in caughtMsg
    check "TopSecretPasswordNeverLeak" notin caughtMsg

    # Invalid username identifier must NOT include the password in the exception message
    caughtMsg = ""
    try:
      discard parseAuthLine("\"bad;user\" \"AnotherUltraSecret999\"", user, secret, lineNum = 12)
    except ValueError as e:
      caughtMsg = e.msg
    check caughtMsg.len > 0
    check "line #12" in caughtMsg
    check "AnotherUltraSecret999" notin caughtMsg

  test "Load auth string with mixed plaintext and SCRAM hashes":
    let scramStr = formatScramSecret(generateVerifier("hashedpass"))
    let content = "# User credentials file\n" &
      "\"alice\" \"plainpass1\"\n" &
      "\"bob\" \"" & scramStr & "\"\n" &
      "carol:plainpass2\n"
    let catalog = newUserCatalog()
    catalog.loadAuthString(content)

    check catalog.len == 3
    check catalog.hasUser("alice") == true
    check catalog.hasUser("bob") == true
    check catalog.hasUser("carol") == true
    check catalog.hasUser("eve") == false

    # Verify alice can authenticate
    var aliceVer: ScramVerifier
    check catalog.getVerifier("alice", aliceVer) == true
    var aliceServer = newScramServerSession(aliceVer)
    var aliceClient = newScramClient("alice", "plainpass1")
    let a1 = aliceClient.buildClientFirstMessage()
    let as1 = aliceServer.processClientFirstAndBuildChallenge(a1)
    let a2 = aliceClient.processServerFirstAndBuildFinal(as1)
    let (aValid, aSig) = aliceServer.verifyClientFinal(a2)
    check aValid == true
    check aliceClient.verifyServerFinalMessage("v=" & aSig) == true

    # Verify bob (precomputed SCRAM hash) can authenticate
    var bobVer: ScramVerifier
    check catalog.getVerifier("bob", bobVer) == true
    var bobServer = newScramServerSession(bobVer)
    var bobClient = newScramClient("bob", "hashedpass")
    let b1 = bobClient.buildClientFirstMessage()
    let bs1 = bobServer.processClientFirstAndBuildChallenge(b1)
    let b2 = bobClient.processServerFirstAndBuildFinal(bs1)
    let (bValid, bSig) = bobServer.verifyClientFinal(b2)
    check bValid == true
    check bobClient.verifyServerFinalMessage("v=" & bSig) == true

  test "writeSecureAuthFile enforces POSIX 0600 permissions":
    let tmpFile = getTempDir() / "test_secure_userlist.txt"
    let v = generateVerifier("secpass")
    let scramStr = formatScramSecret(v)
    try:
      writeSecureAuthFile(tmpFile, @[("dan", scramStr)])
      check fileExists(tmpFile) == true
      check checkFilePermissions(tmpFile) == true
      when defined(posix):
        var st: Stat
        check stat(cstring(tmpFile), st) == 0
        check (int(st.st_mode) and 0o777) == 0o600
        # Open permissions to 0644 and verify checkFilePermissions detects it
        discard chmod(cstring(tmpFile), Mode(0o644))
        check checkFilePermissions(tmpFile) == false
        discard chmod(cstring(tmpFile), Mode(0o600))
      let cat = loadAuthFile(tmpFile)
      check cat.len == 1
      check cat.hasUser("dan") == true
    finally:
      if fileExists(tmpFile):
        removeFile(tmpFile)

  test "Live pg_shadow SCRAM-SHA-256 export and authentication":
    let tmpFile = getTempDir() / "test_pg_shadow_export.txt"
    try:
      waitFor (proc() {.async.} =
        let conn = await connectBackend(
          host = "127.0.0.1",
          port = Port(5432),
          user = "postgres",
          password = "",
          database = "postgres",
          connId = 1
        )
        discard await conn.executeSimple("SET password_encryption = 'scram-sha-256'; ALTER ROLE hermes_alice WITH LOGIN PASSWORD 'AliceSecret!2026'; ALTER ROLE hermes_bob WITH LOGIN PASSWORD 'BobSecret!2026';")
        let pairs = await fetchPgShadowUsers(conn)
        await conn.terminate()
        check pairs.len > 0

        writeSecureAuthFile(tmpFile, pairs)
        check checkFilePermissions(tmpFile) == true

        let cat = loadAuthFile(tmpFile)
        check cat.hasUser("hermes_alice") == true
        check cat.hasUser("hermes_bob") == true

        # Verify Alice can complete SCRAM-SHA-256 handshake against the exported pg_shadow verifier
        var aliceVer: ScramVerifier
        check cat.getVerifier("hermes_alice", aliceVer) == true
        var aliceServer = newScramServerSession(aliceVer)
        var aliceClient = newScramClient("hermes_alice", "AliceSecret!2026")
        let a1 = aliceClient.buildClientFirstMessage()
        let as1 = aliceServer.processClientFirstAndBuildChallenge(a1)
        let a2 = aliceClient.processServerFirstAndBuildFinal(as1)
        let (aValid, aSig) = aliceServer.verifyClientFinal(a2)
        check aValid == true
        check aliceClient.verifyServerFinalMessage("v=" & aSig) == true
      )()
    finally:
      if fileExists(tmpFile):
        removeFile(tmpFile)

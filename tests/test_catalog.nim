import std/[unittest, os]
import hermespg/auth/catalog
import hermespg/crypto/scram

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

  test "Load auth file from disk":
    let tmpFile = getTempDir() / "test_userlist.txt"
    writeFile(tmpFile, "\"dan\" \"danpass\"\n\"erin\" \"erinpass\"\n")
    try:
      let cat = loadAuthFile(tmpFile)
      check cat.len == 2
      check cat.hasUser("dan") == true
      check cat.hasUser("erin") == true
    finally:
      removeFile(tmpFile)

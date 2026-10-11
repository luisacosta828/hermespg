import std/[unittest, base64, strutils]
import hermespg/crypto/scram

proc toString(a: openArray[char]): string =
  result = newString(a.len)
  if a.len > 0: copyMem(addr result[0], unsafeAddr a[0], a.len)

suite "SCRAM-SHA-256 and Cryptographic Primitives":
  test "HMAC-SHA-256 standard vector (RFC 4231 Test Case 2)":
    let key = "Jefe"
    let data = "what do ya want for nothing?"
    let hmac = hmacSha256(key, data)
    check toHex(hmac) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"

  test "PBKDF2-HMAC-SHA-256 standard vector (RFC 6070)":
    let password = "password"
    let salt = "salt"
    let pbkdf2 = pbkdf2HmacSha256(password, salt, 4096)
    check toHex(pbkdf2) == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"

  test "RFC 7677 SCRAM-SHA-256 official test vectors":
    let password = "pencil"
    let salt = decode("QSXCR+Q6sek8bf92")
    let iterations = 4096

    let saltedPassword = pbkdf2HmacSha256(password, salt, iterations)
    let clientKey = hmacSha256(saltedPassword, "Client Key")
    let storedKey = sha256(clientKey)
    let serverKey = hmacSha256(saltedPassword, "Server Key")

    check encode(toString(clientKey)) == "SmcBhAwfyDAcNlLozwyKvSgghht9qugjq6emKUbktnA="
    check encode(toString(storedKey)) == "FO+9jBb3MUukt6jJnzjPZOWc5ow/Pu6JtPyju0aqaE8="
    check encode(toString(serverKey)) == "qxJ1SbmSAi5EcS0J5Ck/cKAm/+Ixa+Kwp63f4OHDgzo="

  test "Full mock SCRAM-SHA-256 client exchange roundtrip":
    var client = newScramClient("postgres", "secretpassword")
    let firstMsg = client.buildClientFirstMessage()
    check firstMsg.startsWith("n,,n=postgres,r=")
    check client.clientNonce.len == 24

    # Simulate server response
    let serverNonce = client.clientNonce & "SERVER_SALT_AND_NONCE_EXT"
    let serverSalt = encode("unique_salt_12345")
    let serverFirst = "r=" & serverNonce & ",s=" & serverSalt & ",i=4096"

    let clientFinal = client.processServerFirstAndBuildFinal(serverFirst)
    check clientFinal.startsWith("c=biws,r=" & serverNonce & ",p=")

    # Verify server signature validation
    var expectedServerSigStr = newString(32)
    copyMem(addr expectedServerSigStr[0], addr client.serverSignature[0], 32)
    let validServerFinal = "v=" & encode(expectedServerSigStr)
    check client.verifyServerFinalMessage(validServerFinal)

    # Reject tampered server signature
    let invalidServerFinal = "v=INVALID_SIGNATURE_TAMPERED_A=="
    check not client.verifyServerFinalMessage(invalidServerFinal)

  test "Full mutual SCRAM-SHA-256 exchange between Client and Server":
    let verifier = generateVerifier("mysecretpassword")
    var server = newScramServerSession(verifier)
    var client = newScramClient("myuser", "mysecretpassword")

    # 1. Client first
    let clientFirst = client.buildClientFirstMessage()
    # 2. Server challenge
    let serverFirst = server.processClientFirstAndBuildChallenge(clientFirst)
    # 3. Client final
    let clientFinal = client.processServerFirstAndBuildFinal(serverFirst)
    # 4. Server verify
    let (valid, serverSig) = server.verifyClientFinal(clientFinal)
    check valid == true
    check client.verifyServerFinalMessage("v=" & serverSig) == true

  test "Server rejects invalid password with ClientProof mismatch":
    let verifier = generateVerifier("correctpassword")
    var server = newScramServerSession(verifier)
    var badClient = newScramClient("myuser", "wrongpassword")

    let clientFirst = badClient.buildClientFirstMessage()
    let serverFirst = server.processClientFirstAndBuildChallenge(clientFirst)
    let clientFinal = badClient.processServerFirstAndBuildFinal(serverFirst)
    let (valid, _) = server.verifyClientFinal(clientFinal)
    check valid == false


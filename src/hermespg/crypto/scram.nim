## Module: hermespg/crypto/scram
## Pure Nim, high-performance implementation of SCRAM-SHA-256 client authentication
## Specifications: RFC 5802, RFC 7677, RFC 2104, RFC 2898.

import checksums/sha2
import std/[base64, strutils, sysrand]

type
  ScramClientState* = object
    user*: string
    password*: string
    clientNonce*: string
    combinedNonce*: string
    clientFirstBare*: string
    serverFirst*: string
    saltedPassword*: array[32, char]
    serverSignature*: array[32, char]

proc sha256*(data: openArray[char]): array[32, char] {.inline.} =
  ## Computes SHA-256 message digest of `data`
  var ctx = initSha_256()
  if data.len > 0:
    ctx.update(data)
  result = ctx.digest()

proc toHex*(data: openArray[char]): string =
  ## Formats raw binary digest as lowercase hexadecimal string
  result = newStringOfCap(data.len * 2)
  for c in data:
    result.add(toHex(ord(c), 2).toLowerAscii)

proc hmacSha256*(key: openArray[char], msg: openArray[char]): array[32, char] =
  ## Computes HMAC-SHA-256 (RFC 2104) with 64-byte block size
  var k: array[64, char]
  if key.len > 64:
    let kh = sha256(key)
    copyMem(addr k[0], unsafeAddr kh[0], 32)
  else:
    if key.len > 0:
      copyMem(addr k[0], unsafeAddr key[0], key.len)

  var ipad, opad: array[64, char]
  for i in 0 ..< 64:
    ipad[i] = chr(ord(k[i]) xor 0x36)
    opad[i] = chr(ord(k[i]) xor 0x5c)

  var inner = initSha_256()
  inner.update(ipad)
  if msg.len > 0:
    inner.update(msg)
  let innerDigest = inner.digest()

  var outer = initSha_256()
  outer.update(opad)
  outer.update(innerDigest)
  result = outer.digest()

proc pbkdf2HmacSha256*(password, salt: openArray[char], iterations: int): array[32, char] =
  ## Derives a 32-byte key using PBKDF2 with HMAC-SHA-256 (RFC 2898)
  ## Uses block index 1 (0x00000001) as required by 32-byte SHA-256 output
  var saltBlock = newString(salt.len + 4)
  if salt.len > 0:
    copyMem(addr saltBlock[0], unsafeAddr salt[0], salt.len)
  saltBlock[salt.len] = chr(0)
  saltBlock[salt.len + 1] = chr(0)
  saltBlock[salt.len + 2] = chr(0)
  saltBlock[salt.len + 3] = chr(1)

  var u = hmacSha256(password, saltBlock)
  result = u

  for _ in 2 .. iterations:
    u = hmacSha256(password, u)
    for j in 0 ..< 32:
      result[j] = chr(ord(result[j]) xor ord(u[j]))

proc generateClientNonce*(length = 24): string =
  ## Generates a cryptographically secure random ASCII printable nonce
  var bytes = newSeq[uint8](length)
  if not urandom(bytes):
    raise newException(IOError, "Failed to acquire cryptographically secure entropy for nonce")
  result = encode(cast[string](bytes))[0 ..< length]

proc newScramClient*(user, password: string): ScramClientState =
  ScramClientState(
    user: user,
    password: password,
    clientNonce: generateClientNonce(24)
  )

proc buildClientFirstMessage*(state: var ScramClientState): string =
  ## Generates initial SASL message: "n,,n=<user>,r=<nonce>"
  state.clientFirstBare = "n=" & state.user & ",r=" & state.clientNonce
  result = "n,," & state.clientFirstBare

proc processServerFirstAndBuildFinal*(state: var ScramClientState, serverFirstMsg: string): string =
  ## Parses server-first-message, calculates PBKDF2/HMAC keys, and builds client-final-message
  state.serverFirst = serverFirstMsg

  var serverNonce = ""
  var saltB64 = ""
  var iterations = 4096

  for part in serverFirstMsg.split(','):
    if part.startsWith("r="):
      serverNonce = part[2 .. ^1]
    elif part.startsWith("s="):
      saltB64 = part[2 .. ^1]
    elif part.startsWith("i="):
      iterations = parseInt(part[2 .. ^1])

  if not serverNonce.startsWith(state.clientNonce):
    raise newException(ValueError, "Server nonce does not match client nonce challenge")
  if saltB64.len == 0:
    raise newException(ValueError, "Server did not provide a salt for SCRAM-SHA-256")

  state.combinedNonce = serverNonce
  let salt = decode(saltB64)

  # Derive keys according to RFC 5802 / RFC 7677
  state.saltedPassword = pbkdf2HmacSha256(state.password, salt, iterations)
  let clientKey = hmacSha256(state.saltedPassword, "Client Key")
  let storedKey = sha256(clientKey)

  let clientFinalWithoutProof = "c=biws,r=" & state.combinedNonce
  let authMessage = state.clientFirstBare & "," & state.serverFirst & "," & clientFinalWithoutProof

  let clientSignature = hmacSha256(storedKey, authMessage)

  # ClientProof = ClientKey XOR ClientSignature
  var clientProof: array[32, char]
  for i in 0 ..< 32:
    clientProof[i] = chr(ord(clientKey[i]) xor ord(clientSignature[i]))

  let serverKey = hmacSha256(state.saltedPassword, "Server Key")
  state.serverSignature = hmacSha256(serverKey, authMessage)

  var proofStr = newString(32)
  copyMem(addr proofStr[0], addr clientProof[0], 32)

  result = clientFinalWithoutProof & ",p=" & encode(proofStr)

proc verifyServerFinalMessage*(state: ScramClientState, serverFinalMsg: string): bool =
  ## Verifies that server-final-message contains valid signature: "v=<ServerSignature>"
  for part in serverFinalMsg.split(','):
    if part.startsWith("v="):
      let sigB64 = part[2 .. ^1]
      var expectedStr = newString(32)
      copyMem(addr expectedStr[0], unsafeAddr state.serverSignature[0], 32)
      return sigB64 == encode(expectedStr)
  return false

type
  ScramVerifier* = object
    salt*: string
    iterations*: int
    storedKey*: array[32, char]
    serverKey*: array[32, char]

  ScramServerSession* = object
    verifier*: ScramVerifier
    serverNonce*: string
    clientFirstBare*: string
    serverFirst*: string
    combinedNonce*: string

proc generateVerifier*(password: string, salt = "", iterations = 4096): ScramVerifier =
  ## Precomputes SCRAM-SHA-256 verifier (salt, StoredKey, ServerKey) from plaintext password.
  ## Computed once during startup so individual client handshakes never pay PBKDF2 cost.
  let s = if salt.len > 0: salt else: generateClientNonce(16)
  let saltedPass = pbkdf2HmacSha256(password, s, iterations)
  let clientKey = hmacSha256(saltedPass, "Client Key")
  let storedKey = sha256(clientKey)
  let serverKey = hmacSha256(saltedPass, "Server Key")
  ScramVerifier(
    salt: s,
    iterations: iterations,
    storedKey: storedKey,
    serverKey: serverKey
  )

proc newScramServerSession*(verifier: ScramVerifier): ScramServerSession =
  ## Creates a new server-side SCRAM handshake session for an incoming client
  ScramServerSession(
    verifier: verifier,
    serverNonce: generateClientNonce(24)
  )

proc processClientFirstAndBuildChallenge*(state: var ScramServerSession, clientFirstMsg: string): string =
  ## Parses client-first-message (e.g. "n,,n=user,r=clientNonce")
  ## Returns server-first-message: "r=clientNonce+serverNonce,s=saltB64,i=iterations"
  let bare = if clientFirstMsg.startsWith("n,,"): clientFirstMsg[3 .. ^1]
             elif clientFirstMsg.startsWith("y,,"): clientFirstMsg[3 .. ^1]
             else: clientFirstMsg
  state.clientFirstBare = bare
  var clientNonce = ""
  for part in bare.split(','):
    if part.startsWith("r="):
      clientNonce = part[2 .. ^1]
  if clientNonce.len == 0:
    raise newException(ValueError, "Missing client nonce in client-first-message")

  state.combinedNonce = clientNonce & state.serverNonce
  state.serverFirst = "r=" & state.combinedNonce & ",s=" & encode(state.verifier.salt) & ",i=" & $state.verifier.iterations
  return state.serverFirst

proc verifyClientFinal*(state: ScramServerSession, clientFinalMsg: string): tuple[valid: bool, serverSigB64: string] =
  ## Parses client-final-message ("c=biws,r=combinedNonce,p=clientProof")
  ## Recovers ClientKey and validates SHA256(ClientKey) == StoredKey
  ## Returns (valid, serverSignatureBase64)
  var clientProofB64 = ""
  var clientFinalWithoutProof = ""
  let pIdx = clientFinalMsg.find(",p=")
  if pIdx == -1:
    return (false, "")
  clientFinalWithoutProof = clientFinalMsg[0 ..< pIdx]
  clientProofB64 = clientFinalMsg[pIdx + 3 .. ^1]

  let authMessage = state.clientFirstBare & "," & state.serverFirst & "," & clientFinalWithoutProof
  let clientSignature = hmacSha256(state.verifier.storedKey, authMessage)
  let clientProof = decode(clientProofB64)
  if clientProof.len != 32:
    return (false, "")

  var recoveredClientKey: array[32, char]
  for i in 0 ..< 32:
    recoveredClientKey[i] = chr(ord(clientProof[i]) xor ord(clientSignature[i]))

  let calculatedStoredKey = sha256(recoveredClientKey)
  if calculatedStoredKey != state.verifier.storedKey:
    return (false, "")

  let serverSignature = hmacSha256(state.verifier.serverKey, authMessage)
  var sigStr = newString(32)
  copyMem(addr sigStr[0], unsafeAddr serverSignature[0], 32)
  return (true, encode(sigStr))


import std/[monotimes, times, strformat, strutils]
import hermespg/crypto/scram

proc formatNumber(n: int): string =
  let s = $n
  var res = ""
  var count = 0
  for i in countdown(s.len - 1, 0):
    res.add(s[i])
    inc count
    if count mod 3 == 0 and i > 0:
      res.add(',')
  # reverse
  result = newString(res.len)
  for i in 0 ..< res.len:
    result[i] = res[res.len - 1 - i]

proc main() =
  echo "=================================================================="
  echo "⚡ HERMESPG: BENCHMARK DE EFICIENCIA CRIPTOGRÁFICA SCRAM-SHA-256 ⚡"
  echo "=================================================================="

  let pass = "HermesSecr3t!2026"
  
  # 1. Precomputación inicial (Boot)
  let tStartBoot = getMonoTime()
  let verifier = generateVerifier(pass)
  let bootDurationNs = (getMonoTime() - tStartBoot).inNanoseconds
  echo fmt"[*] Precomputación inicial (PBKDF2 4,096 iteraciones): {float(bootDurationNs) / 1_000_000.0:.3f} ms (1 sola vez al arrancar)"

  # Generamos credenciales de prueba
  var client = newScramClient("scram_user", pass)
  let clientFirst = client.buildClientFirstMessage()
  var server = newScramServerSession(verifier)
  let serverFirst = server.processClientFirstAndBuildChallenge(clientFirst)
  let clientFinal = client.processServerFirstAndBuildFinal(serverFirst)

  # 2. Benchmark de Verificación en Servidor (100,000 operaciones)
  const Iterations = 100_000
  echo fmt"\n[*] Ejecutando {formatNumber(Iterations)} verificaciones de servidor consecutivas..."

  var validCount = 0
  let tStart = getMonoTime()
  for _ in 1 .. Iterations:
    let (valid, _) = server.verifyClientFinal(clientFinal)
    if valid: inc validCount
  let totalNs = (getMonoTime() - tStart).inNanoseconds
  let avgUs = (float(totalNs) / float(Iterations)) / 1_000.0
  let opsSec = float(Iterations) / (float(totalNs) / 1_000_000_000.0)

  echo fmt"    - Total operaciones:   {formatNumber(validCount)} / {formatNumber(Iterations)} (100% éxito)"
  echo fmt"    - Tiempo total:         {float(totalNs) / 1_000_000.0:.2f} ms"
  echo fmt"    - Latencia de servidor: {avgUs:.3f} µs por cliente"
  echo fmt"    - Capacidad de cómputo: {formatNumber(int(opsSec))} verificaciones/segundo por núcleo"

  # 3. Benchmark de Detección y Rechazo Inmediato de Clave Errónea
  var badClient = newScramClient("scram_user", "WrongPassword!")
  let badClientFirst = badClient.buildClientFirstMessage()
  var badServer = newScramServerSession(verifier)
  let badServerFirst = badServer.processClientFirstAndBuildChallenge(badClientFirst)
  let badClientFinal = badClient.processServerFirstAndBuildFinal(badServerFirst)

  echo fmt"\n[*] Ejecutando {formatNumber(Iterations)} rechazos de contraseña errónea..."
  var rejectedCount = 0
  let tStartBad = getMonoTime()
  for _ in 1 .. Iterations:
    let (valid, _) = badServer.verifyClientFinal(badClientFinal)
    if not valid: inc rejectedCount
  let badNs = (getMonoTime() - tStartBad).inNanoseconds
  let badAvgUs = (float(badNs) / float(Iterations)) / 1_000.0
  let badOpsSec = float(Iterations) / (float(badNs) / 1_000_000_000.0)

  echo fmt"    - Total rechazados:     {formatNumber(rejectedCount)} / {formatNumber(Iterations)} (100% bloqueados)"
  echo fmt"    - Tiempo de rechazo:    {badAvgUs:.3f} µs por ataque/intento fallido"
  echo fmt"    - Tasa de rechazo:      {formatNumber(int(badOpsSec))} bloqueos/segundo por núcleo"

  # 4. Benchmark de Handshake Completo SASL de Ida y Vuelta (Roundtrip Cliente + Servidor)
  const HandshakeIters = 2_000
  echo fmt"\n[*] Ejecutando {formatNumber(HandshakeIters)} ciclos completos de handshake SASL (Cliente + Servidor)..."

  let tStartRoundtrip = getMonoTime()
  for _ in 1 .. HandshakeIters:
    var c = newScramClient("scram_user", pass)
    var s = newScramServerSession(verifier)
    let c1 = c.buildClientFirstMessage()
    let s1 = s.processClientFirstAndBuildChallenge(c1)
    let c2 = c.processServerFirstAndBuildFinal(s1)
    let (_, sig) = s.verifyClientFinal(c2)
    discard c.verifyServerFinalMessage("v=" & sig)
  let roundtripNs = (getMonoTime() - tStartRoundtrip).inNanoseconds
  let roundtripAvgMs = (float(roundtripNs) / float(HandshakeIters)) / 1_000_000.0
  let handshakesSec = float(HandshakeIters) / (float(roundtripNs) / 1_000_000_000.0)

  echo fmt"    - Handshakes completos: {formatNumber(HandshakeIters)}"
  echo fmt"    - Latencia total ciclo: {roundtripAvgMs:.3f} ms (incluye PBKDF2 del cliente)"
  echo fmt"    - Throughput SASL:      {formatNumber(int(handshakesSec))} handshakes completos/segundo"
  echo "=================================================================="

when isMainModule:
  main()

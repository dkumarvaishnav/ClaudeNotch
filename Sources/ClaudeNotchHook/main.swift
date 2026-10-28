import Foundation
import HookProtocol

// claudenotch-hook permission | event | wait
//
// Claude Code runs this for hook events (see HookInstaller.swift). It forwards the event to ClaudeNotch
// on 127.0.0.1 and, for permission requests and replies, waits for your answer in the notch.
// Whenever ClaudeNotch is not running, does not answer, or cannot prove it is ClaudeNotch, this exits 0
// without output, so Claude Code carries on exactly as if the hook were not there.

let mode = CommandLine.arguments.dropFirst().first ?? "event"
guard ["permission", "event", "wait"].contains(mode) else { exit(0) }
let input = FileHandle.standardInput.readDataToEndOfFile()

guard let secret = HookAuth.loadSecret(),
      let url = URL(string: "http://127.0.0.1:\(HookAuth.port)/\(mode)?pid=\(getppid())") else { exit(0) }

// Permission requests and replies wait for you; Claude Code's own hook timeout ends them sooner.
let wait: TimeInterval = mode == "event" ? 3 : 6 * 3600
let nonce = HookAuth.newNonce()
let time = Int(Date().timeIntervalSince1970)
var request = URLRequest(url: url, timeoutInterval: wait)
request.httpMethod = "POST"
request.httpBody = input
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.setValue(nonce, forHTTPHeaderField: HookAuth.nonceHeader)
request.setValue(String(time), forHTTPHeaderField: HookAuth.timeHeader)
request.setValue(HookAuth.requestSignature(secret: secret, path: "/" + mode, time: time, nonce: nonce, body: input),
                 forHTTPHeaderField: HookAuth.signatureHeader)

let config = URLSessionConfiguration.ephemeral
config.timeoutIntervalForRequest = wait
config.timeoutIntervalForResource = wait
config.connectionProxyDictionary = [:] // never send localhost through a proxy

var body = Data()
var status = 0
var proof: String?
let finished = DispatchSemaphore(value: 0)
URLSession(configuration: config).dataTask(with: request) { data, response, _ in
    body = data ?? Data()
    let http = response as? HTTPURLResponse
    status = http?.statusCode ?? 0
    proof = http?.value(forHTTPHeaderField: HookAuth.proofHeader)
    finished.signal()
}.resume()
finished.wait()

// Only an answer signed for this very request counts; anything else is ignored.
guard status == 200, !body.isEmpty,
      HookAuth.matches(proof, HookAuth.responseProof(secret: secret, nonce: nonce, status: status, body: body)) else { exit(0) }

switch mode {
case "permission":
    // The decision JSON, exactly as Claude Code expects it on stdout.
    FileHandle.standardOutput.write(body)
    exit(0)
case "wait":
    // asyncRewake: exit code 2 wakes Claude with this text.
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let reply = object["reply"] as? String, !reply.isEmpty else { exit(0) }
    FileHandle.standardError.write(Data("The user replied from the ClaudeNotch notch:\n\(reply)\n".utf8))
    exit(2)
default:
    exit(0)
}

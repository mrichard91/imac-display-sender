// idp-probe: check a receiver and the link to it without the menu bar app.
//
//   idp-probe <host> [--port 7878] [--speed-test-ms 1000] [--pings 5] [--verbose]
//
// Connects, prints HELLO, measures RTT, runs a speed test when the receiver
// supports it, then says GOODBYE NORMAL. Exit status 0 on success.

import Foundation
import IDPCore
import IDPProtocol

struct ProbeOptions {
    var address: ReceiverAddress
    var speedTestMs: UInt32 = 1_000
    var pings = 5
    var verbose = false
}

func usage(_ message: String? = nil) -> Never {
    if let message { FileHandle.standardError.write(Data("error: \(message)\n".utf8)) }
    let text = """
        usage: idp-probe <host[:port]> [--port 7878] [--speed-test-ms 1000] [--pings 5] [--verbose]
          --speed-test-ms N   speed test duration, 100–10000, 0 to skip (default 1000)
          --pings N           PONGs to wait for before reporting RTT, 0 to skip (default 5)

        """
    FileHandle.standardError.write(Data(text.utf8))
    exit(2)
}

func parseOptions(_ arguments: [String]) -> ProbeOptions {
    var host: String?
    var port: UInt16?
    var speedTestMs: UInt32 = 1_000
    var pings = 5
    var verbose = false
    var iterator = arguments.dropFirst().makeIterator()
    func value(for flag: String) -> String {
        guard let value = iterator.next() else { usage("\(flag) needs a value") }
        return value
    }
    while let argument = iterator.next() {
        switch argument {
        case "--port":
            guard let parsed = UInt16(value(for: argument)), parsed > 0 else { usage("bad --port") }
            port = parsed
        case "--speed-test-ms":
            guard let parsed = UInt32(value(for: argument)),
                  parsed == 0 || SpeedTestStart.durationRangeMs.contains(parsed)
            else { usage("--speed-test-ms must be 0 or 100–10000") }
            speedTestMs = parsed
        case "--pings":
            guard let parsed = Int(value(for: argument)), parsed >= 0 else { usage("bad --pings") }
            pings = parsed
        case "--verbose", "-v":
            verbose = true
        case "--help", "-h":
            usage()
        default:
            guard !argument.hasPrefix("-"), host == nil else { usage("unexpected argument \(argument)") }
            host = argument
        }
    }
    guard let host, var address = ReceiverAddress.parse(host) else { usage("missing receiver host") }
    if let port { address.port = port }
    return ProbeOptions(address: address, speedTestMs: speedTestMs, pings: pings, verbose: verbose)
}

func describe(_ caps: Hello.Caps) -> String {
    var names: [String] = []
    if caps.contains(.canScale) { names.append("scale") }
    if caps.contains(.stats) { names.append("stats") }
    if caps.contains(.speedTest) { names.append("speed-test") }
    return String(format: "0x%X", caps.rawValue) + (names.isEmpty ? "" : " (\(names.joined(separator: ", ")))")
}

func printHello(_ hello: Hello) {
    print("HELLO   \"\(hello.name)\", protocol v\(hello.protocolVersion)")
    print("        panel \(hello.panelWidthPx)x\(hello.panelHeightPx) @ \(String(format: "%.3f", hello.refreshHz)) Hz, "
        + "\(hello.physicalWidthMm)x\(hello.physicalHeightMm) mm")
    print("        display_id " + String(format: "0x%016llX", hello.displayId)
        + ", codecs " + String(format: "0x%X", hello.codecs.rawValue) + ", caps \(describe(hello.caps))")
    print("        max bitrate " + (hello.maxBitrateKbps == 0 ? "no preference" : "\(hello.maxBitrateKbps) kbit/s"))
}

let options = parseOptions(CommandLine.arguments)
Log.minimumLevel = options.verbose ? .debug : .warn

var configuration = Connection.Configuration()
configuration.pingInterval = 0.2  // PROTOCOL §6.8 allows up to 10/s
let connection = Connection(host: options.address.host, port: options.address.port, configuration: configuration)
let events = connection.events()
connection.start()

var hello: Hello?
var link: LinkInfo?
var pongs = 0
var lastRtt: UInt64?

eventLoop: for await event in events {
    switch event {
    case .connected(let info):
        link = info
        print("link    \(options.address) via \(info.summary), local \(info.localAddress ?? "?")")
    case .linkChanged(let info):
        link = info
    case .hello(let received):
        hello = received
        printHello(received)
        if options.pings == 0 { break eventLoop }
    case .rttUpdated(let microseconds):
        pongs += 1
        lastRtt = microseconds
        if pongs >= options.pings { break eventLoop }
    case .message:
        break
    case .closed(let reason):
        print("failed  \(reason)")
        exit(1)
    }
}

if let lastRtt {
    print(String(format: "RTT     %.2f ms (minimum of last %d PINGs)", Double(lastRtt) / 1_000, min(pongs, 5)))
}

var exitCode: Int32 = 0
if let hello, options.speedTestMs > 0 {
    if hello.caps.contains(.speedTest) {
        switch await connection.speedTest(durationMs: options.speedTestMs) {
        case .success(let report):
            let megabytes = Double(report.bytesReceived) / 1_000_000
            print(String(format: "speed   %.1f Mbit/s (%.1f MB in %.1f ms)", report.mbps, megabytes,
                         Double(report.elapsedUs) / 1_000)
                + " over \(report.link?.summary ?? link?.summary ?? "unknown link")")
        case .failure(let error):
            print("speed   failed: \(error)")
            exitCode = 1
        }
    } else {
        print("speed   receiver does not support speed tests (caps bit 2 clear)")
    }
}

connection.close(goodbye: .normal)
try? await Task.sleep(nanoseconds: 300_000_000)  // let GOODBYE reach the socket
exit(exitCode)

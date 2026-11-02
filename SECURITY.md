# Security policy

This repository is the macOS menu bar sender for the iMac Display Protocol
(IDP), plus the `idp-probe` command-line tool. The Linux receiver lives in
`imac-display-receiver` and has its own `SECURITY.md`; that repository is also
the source of truth for `PROTOCOL.md`.

> [!WARNING]
> IDP v1 has **no authentication and no encryption**, by design. Whatever is on
> the virtual display is streamed in plaintext to whichever host answers at the
> address you entered. Use it only on a cable or a trusted LAN, and never
> across an untrusted network or the internet. See
> [`PROTOCOL.md` §10](PROTOCOL.md#10-security).

## Scope

In scope:

- The app (`Sources/ImacDisplaySender`), the protocol and networking code
  (`Sources/IDPProtocol`, `Sources/IDPCore`), the private-API bridge
  (`Sources/CGVirtualDisplayBridge`), `idp-probe` and `scripts/`.
- How the sender handles every message a receiver can send, including HELLO
  values that end up in the virtual display, the menu and preferences.

Out of scope: bugs in macOS frameworks (ScreenCaptureKit, VideoToolbox,
Network.framework, the private `CGVirtualDisplay` API) unless the sender uses
them in a way that creates the problem. Problems in `PROTOCOL.md` itself
belong in the receiver repository, but a report here is also fine.

## Supported versions

| version                              | supported |
|--------------------------------------|-----------|
| `main` branch, protocol v1           | yes       |
| older commits, forks                 | no        |

There are no release branches or signed releases; fixes land on `main`.

## Known limitations (not vulnerabilities)

These follow from v1 having no authentication or encryption and are documented
in [`PROTOCOL.md` §10](PROTOCOL.md#10-security). Reports that only restate them
will be closed, but ideas for fixing them in v2 are welcome as ordinary issues
(see [`PLAN.md` §9](PLAN.md#9-public-release-and-next-steps)).

| limitation | consequence |
|------------|-------------|
| No encryption | The virtual display is sent as plaintext HEVC over TCP; anyone who can capture the traffic can record and decode it. |
| Receiver identity is not verified | The sender streams to any host that sends a v1 HELLO with the HEVC codec bit. There is no prompt, certificate or fingerprint. Hostnames go through DNS/mDNS, which can be spoofed. |
| Automatic reconnect | *Reconnect automatically* (on by default) retries the same host and port indefinitely (1–10 s backoff), including after `BUSY` and for a connection started with `--host` at launch; if that address now belongs to another machine, it gets the stream. |
| Receiver-supplied values are trusted | The receiver's name, panel geometry and `display_id` from HELLO name and shape the virtual display. A spoofed receiver that replays a genuine `display_id` gets the saved arrangement, so windows you keep on that display open on the impostor. |
| Receiver-supplied text | The HELLO name and GOODBYE text are shown in the menu, stored in the recent-receivers list and logged. |
| Local errors are sent to the receiver | When the sender gives up on a stream (display, capture or encoder failure) its GOODBYE `INTERNAL_ERROR` carries the macOS error description in plaintext, e.g. "Could not switch to 3840×2160: …". |
| No authentication on the receiver | Anyone who can reach the receiver's port can show video on it or hold its single sender slot. |
| Unbounded receiver input (PLAN S8) | HELLO geometry and refresh rate reach `CGVirtualDisplay` without bounds checks; KEYFRAME_REQUEST and PING are answered without a rate limit (forced keyframes cost CPU, bandwidth and battery); any known message type is buffered up to the 64 MiB framing limit before its length is checked. |

Mitigations available today: use a dedicated cable or a LAN you control,
connect by IP address, turn off *Reconnect automatically* on networks you do
not control, check the receiver's address before connecting, keep password
managers, mail and other sensitive windows off the virtual display, and
firewall the receiver to your Mac's address (see the receiver's
`docs/network-setup.md`).

## What counts as a vulnerability

Report privately anything that goes beyond the limitations above, for example:

- A crash, hang, memory use beyond the 64 MiB framing limit, or memory
  unsafety in the sender caused by bytes a receiver (or anyone on the path)
  can send, including through HELLO values passed to `CGVirtualDisplay`
  (beyond the missing bounds checks listed above).
- Capturing or sending anything other than the virtual display: the built-in
  or other screens, audio, or data from other apps.
- The sender connecting somewhere the user did not ask it to, or continuing to
  stream after **Disconnect**.
- Leaking local data to the receiver beyond what PROTOCOL.md specifies.
- Code execution or privilege escalation, including through the app bundle,
  its signing or `scripts/`.
- Documentation that leaves users more exposed than it says.

## Reporting a vulnerability

Do **not** open a public issue, pull request or discussion.

Use GitHub private vulnerability reporting: open this repository's
**Security** tab and choose **Report a vulnerability**. Include the commit you
tested, the macOS version and Mac model, the steps or bytes that trigger the
problem, and the impact you observed.

If the **Report a vulnerability** button is missing, open a public issue that
asks for a private contact, without any details.

This is a personal project maintained in spare time. You should get an
acknowledgement within about two weeks; a fix, or a documented limitation if
the problem is inherent to v1, follows as time allows. Please allow 90 days, or
until a fix is published, before disclosing publicly. Credit is given in the
fix's commit and advisory unless you ask otherwise.

If the problem is in the protocol and also affects the receiver, one report in
either repository is enough.

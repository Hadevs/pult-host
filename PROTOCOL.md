# Pult wire protocol (v1)

One TCP connection carries everything, with `TCP_NODELAY`. Video flows
host → client and input flows client → host, so neither direction waits
behind the other.

Two ports:

| Port | Transport | Who may connect |
|------|-----------|-----------------|
| 7777 | plain TCP | only the host's own networks (LAN, Tailscale); also hands a new client the remote key |
| 7778 | TLS 1.2, `TLS_PSK_WITH_AES_128_GCM_SHA256` | anyone with the 256-bit pre-shared key — the only port meant to face the internet |

The TLS key is derived from the host's 32-byte secret with
`HMAC-SHA256("Pult TLS v1")`; the raw secret never leaves the Keychain.

## Framing

    [u32 length][u8 type][payload...]

Big-endian. `length` counts the type byte plus the payload. Messages larger
than 32 MiB are a protocol error. An unknown `type` is skipped, so a newer
peer can add messages without breaking an older one.

## Handshake

1. Client → `hello` (`u8 version`, `str code`). On 7778 the key already
   proved identity, so `code` is ignored there.
2. Host → `helloOK` (`ScreenInfo`) then `pairInfo` (`PairInfo`), or
   `helloDenied` (`str reason`) followed by a close.

`str` is a `u16` length then UTF-8. `PairInfo` carries the host id, name,
the 32-byte key and the LAN / public-v4 / IPv6 addresses to try later.

## Messages

Client → host: `mouseMove` `mouseButton` `mouseMoveRelative` `scroll`
`key` `text` `dictation` `image` `unlock` `requestKeyframe` `ping`
`frameAck`.

Host → client: `video` `cursorImage` `cursorPos` `screenInfo`
`dictationResult` `unlockResult` `lockState` `imageResult` `pong`.

Each type's exact payload is documented inline in
[`Protocol.swift`](Sources/PultShared/Protocol.swift).

## Video

`video` carries one H.264 access unit in AVCC form (4-byte NAL lengths).
Keyframes also carry SPS and PPS. The host keeps at most
`maxFramesInFlight` (4) frames ahead of the client's `frameAck`, then skips
captures — so latency stays bounded instead of a queue building up.

## Coordinates

Pointer messages are in display points, the space of `ScreenInfo.width/height`.
`mouseMoveRelative` is a raw delta for game cameras: the host leaves the
absolute cursor where it is and sends the motion as event deltas.

---
title: "AQCW payOne response contract"
tags: ["aqcw", "payment", "payOne", "disassembly", "protocol"]
created: 2026-08-14T11:15:51.311Z
updated: 2026-08-14T11:59:06.415Z
sources: []
links: ["aqcw-payone-local-payment-progress.md"]
category: debugging
confidence: high
schemaVersion: 1
---

# AQCW payOne response contract

## Verified disassembly contract

The live AQCW flow posts form-urlencoded data to `/payOne`; it does not use the installed netpay TLV endpoint. In extracted `smsend.ext`, response callback `0x3358` calls parser `0x1fc4`, requires parser return 0, requires parsed status 200 at `0x338e..0x3392`, then compares the parsed response ID with the current request ID at `0x3394..0x33a0`. Request generation stores the ID from `0x655c` at record offset 508, serialized after `&msgid=` at `0x0f06..0x0f0e`.

Thumb PC-relative disassembly initially led to a rejected 16-byte tag/value hypothesis. Dynamic branch watches proved that each record is instead `BE32(type) || BE32(length) || value`. The parser consumes these fields:

- TLV 100: four-byte big-endian status, required to equal 200;
- TLV 101: four-byte big-endian response ID, required to equal the current request `msgid`;
- TLV 200: one-byte action; action 1 with zero SMS items enters the direct completion path.

The minimal success body is therefore:

```text
TLV(100, BE32(200)) || TLV(101, BE32(request msgid)) || TLV(200, 0x01)
```

For captured `msgid=5708` (`0x164c`), the 33-byte body is:

```text
0000006400000004000000c8
00000065000000040000164c
000000c80000000101
```

Watched execution reaches action dispatch `0x33d0` with action 1, direct completion `0x865c`, and state 7. Action 0 clears the request and leaves the waiting page; other values enter failure `0x85f0`. `application/octet-stream` is a semantic MIME choice; the client validates HTTP framing/status but does not inspect Content-Type.

Implementation boundary: exact POST `/payOne` accepts exactly one decimal uint32 `msgid` and returns the response above; exact POST `/payOneAsTlv` preserves the existing TLV behavior; malformed known requests and unknown paths are rejected explicitly, with no generic success fallback and no application-specific branch. The executable may bind `PORT=0` and reports the selected listener address after a successful bind so tests can own an isolated server lifecycle.

#!/usr/bin/env python3
"""
JNDI canary listener for the Avi WAF Log4Shell demo.

Stands in for an attacker's LDAP referral server, but does NOT serve any
payload class. It exists only to observe: when a vulnerable Log4j backend
parses a ${jndi:ldap://<this-host>:1389/<token>} string, it opens an
outbound LDAP connection here. We complete just enough of the LDAP bind
for the client to send its search request (which carries the correlation
token), record the hit, and close. No code is ever served or executed.

Every observed callback is appended as one JSON line to CALLBACKS_FILE so
the console's fire API can correlate a specific request to a specific
callback. Pure standard library, no external dependencies.
"""

import json
import os
import re
import socketserver
import struct
import threading
import time

LISTEN_HOST = os.environ.get("CANARY_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("CANARY_PORT", "1389"))
CALLBACKS_FILE = os.environ.get(
    "CALLBACKS_FILE", "/var/lib/log4shell-demo/callbacks.jsonl"
)

# Correlation tokens issued by the console look like LT + 16 hex chars.
TOKEN_RE = re.compile(rb"LT[0-9a-f]{16}")

_write_lock = threading.Lock()


def _record(src_ip, token):
    entry = {
        "ts": time.time(),
        "src": src_ip,
        "token": token.decode() if token else None,
    }
    line = json.dumps(entry) + "\n"
    with _write_lock:
        os.makedirs(os.path.dirname(CALLBACKS_FILE), exist_ok=True)
        with open(CALLBACKS_FILE, "a") as fh:
            fh.write(line)
            fh.flush()
    print(
        "[canary] callback from {} token={}".format(
            src_ip, entry["token"] or "<none>"
        ),
        flush=True,
    )


def _bind_response_for(request_bytes):
    """Build a minimal anonymous bindResponse(success), echoing the client's
    messageID so the JNDI client proceeds to send its search request."""
    message_id = 1
    # Outer LDAPMessage SEQUENCE is request_bytes[0]==0x30; the messageID
    # INTEGER follows the sequence length. Parse it defensively.
    try:
        if request_bytes and request_bytes[0] == 0x30:
            idx = 2
            # Handle multi-byte length on the outer sequence.
            if request_bytes[1] & 0x80:
                idx = 2 + (request_bytes[1] & 0x7F)
            if request_bytes[idx] == 0x02:  # INTEGER (messageID)
                mlen = request_bytes[idx + 1]
                message_id = int.from_bytes(
                    request_bytes[idx + 2 : idx + 2 + mlen], "big"
                )
    except Exception:
        message_id = 1

    mid = struct.pack("!B", message_id & 0xFF)
    # LDAPMessage { messageID, bindResponse { success, "", "" } }
    bind_response = (
        b"\x61\x07\x0a\x01\x00\x04\x00\x04\x00"  # [APP 1] len7: resultCode 0, "", ""
    )
    inner = b"\x02\x01" + mid + bind_response
    return b"\x30" + struct.pack("!B", len(inner)) + inner


class CanaryHandler(socketserver.BaseRequestHandler):
    def handle(self):
        src_ip = self.client_address[0]
        token = None
        try:
            self.request.settimeout(4.0)
            first = self.request.recv(4096)
            if not first:
                _record(src_ip, None)
                return

            # A token can already appear if the client front-loaded a search.
            m = TOKEN_RE.search(first)
            if m:
                token = m.group(0)

            # Nudge the client to send its search request (carries the path).
            try:
                self.request.sendall(_bind_response_for(first))
                more = self.request.recv(4096)
                if more:
                    m2 = TOKEN_RE.search(more)
                    if m2:
                        token = m2.group(0)
            except Exception:
                pass
        except Exception:
            pass
        finally:
            _record(src_ip, token)


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    os.makedirs(os.path.dirname(CALLBACKS_FILE), exist_ok=True)
    # Touch the file so the console can read it before the first callback.
    open(CALLBACKS_FILE, "a").close()
    server = ThreadedTCPServer((LISTEN_HOST, LISTEN_PORT), CanaryHandler)
    print(
        "[canary] listening on {}:{}  ->  {}".format(
            LISTEN_HOST, LISTEN_PORT, CALLBACKS_FILE
        ),
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Minimal FastCGI client: send one request to php-fpm and print the raw CGI response (headers and body).

Usage: fcgi_get.py HOST PORT SCRIPT_FILENAME [METHOD]
"""

import socket
import struct
import sys


def record(rtype: int, request_id: int, content: bytes) -> bytes:
    return struct.pack("!BBHHBx", 1, rtype, request_id, len(content), 0) + content


def name_value(name: str, value: str) -> bytes:
    def length(x: bytes) -> bytes:
        return struct.pack("!B", len(x)) if len(x) < 128 else struct.pack("!I", len(x) | 0x80000000)

    n, v = name.encode(), value.encode()
    return length(n) + length(v) + n + v


def main() -> None:
    host, port, script = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    method = sys.argv[4] if len(sys.argv) > 4 else "GET"
    params = {
        "SCRIPT_FILENAME": script,
        "REQUEST_METHOD": method,
        "SERVER_PROTOCOL": "HTTP/1.1",
        "GATEWAY_INTERFACE": "CGI/1.1",
        "REQUEST_URI": "/",
        "SCRIPT_NAME": "/x.php",
        "QUERY_STRING": "",
        "SERVER_NAME": "localhost",
        "SERVER_PORT": "80",
        "REMOTE_ADDR": "127.0.0.1",
        "CONTENT_LENGTH": "0",
    }
    out = b""
    with socket.create_connection((host, port)) as s:
        s.sendall(record(1, 1, struct.pack("!HB5x", 1, 0)))  # FCGI_BEGIN_REQUEST, responder
        body = b"".join(name_value(k, v) for k, v in params.items())
        s.sendall(record(4, 1, body) + record(4, 1, b"") + record(5, 1, b""))  # FCGI_PARAMS, empty FCGI_STDIN
        while True:
            header = s.recv(8)
            if len(header) < 8:
                break
            _, rtype, _, clen, plen = struct.unpack("!BBHHBx", header)
            data = b""
            while len(data) < clen + plen:
                data += s.recv(clen + plen - len(data))
            if rtype == 6:  # FCGI_STDOUT
                out += data[:clen]
            if rtype == 3:  # FCGI_END_REQUEST
                break
    print(out.decode(errors="replace"))


if __name__ == "__main__":
    main()

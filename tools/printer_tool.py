#!/usr/bin/env python3
"""Inspect a QL-580N over HTTP or transmit a prepared raster job over TCP."""

from __future__ import annotations

import argparse
from html.parser import HTMLParser
import http.client
from pathlib import Path
import socket
import sys


MAX_HTTP_BYTES = 1024 * 1024
STATUS_PAGES = (
    ("Maintenance", "/printer/maininfo.html"),
    ("Configuration", "/printer/configu.html"),
)
FIELD_NAMES = (
    "Printer Type",
    "Serial no.",
    "Printer Firmware Version",
    "Network Firmware Version",
    "Total Page Count",
    "Total Cut Count",
    "Total Print Length(m)",
    "Media Status",
    "Media Type",
)


class TableRows(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.rows: list[list[str]] = []
        self.row_stack: list[list[str]] = []
        self.cell_stack: list[list[str]] = []
        self.hidden_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in ("script", "style"):
            self.hidden_depth += 1
        elif tag == "tr":
            self.row_stack.append([])
        elif tag in ("td", "th"):
            self.cell_stack.append([])
        elif tag in ("br", "dd", "dt", "p") and self.cell_stack:
            self.cell_stack[-1].append(" ")

    def handle_endtag(self, tag: str) -> None:
        if tag in ("script", "style"):
            self.hidden_depth = max(0, self.hidden_depth - 1)
        elif tag in ("td", "th") and self.cell_stack:
            value = " ".join("".join(self.cell_stack.pop()).split())
            if self.row_stack:
                self.row_stack[-1].append(value)
        elif tag == "tr" and self.row_stack:
            row = self.row_stack.pop()
            if row:
                self.rows.append(row)

    def handle_data(self, data: str) -> None:
        if not self.hidden_depth and self.cell_stack:
            self.cell_stack[-1].append(data)


def fetch_page(host: str, path: str, timeout: float) -> str:
    connection = http.client.HTTPConnection(host, 80, timeout=timeout)
    try:
        connection.request("GET", path, headers={"Accept": "text/html"})
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError(f"GET {path}: HTTP {response.status} {response.reason}")
        content = response.read(MAX_HTTP_BYTES + 1)
        if len(content) > MAX_HTTP_BYTES:
            raise RuntimeError(f"GET {path}: response exceeds {MAX_HTTP_BYTES} bytes")
        return content.decode("iso-8859-1", errors="replace")
    finally:
        connection.close()


def status(host: str, timeout: float) -> int:
    found: dict[str, str] = {}
    errors: list[str] = []
    for name, path in STATUS_PAGES:
        try:
            parser = TableRows()
            parser.feed(fetch_page(host, path, timeout))
            for row in parser.rows:
                for field in FIELD_NAMES:
                    if field in row and row.index(field) + 1 < len(row):
                        found[field] = row[row.index(field) + 1]
        except (OSError, RuntimeError) as exc:
            errors.append(f"{name}: {exc}")

    print(f"Brother QL-580N at {host}")
    for field in FIELD_NAMES:
        if field in found:
            print(f"{field}: {found[field]}")
    for error in errors:
        print(error, file=sys.stderr)
    if not found:
        print("No status fields found on the printer HTTP pages.", file=sys.stderr)
        return 1
    return 0 if not errors else 1


def send(host: str, port: int, timeout: float, path: Path) -> int:
    if path.suffix.lower() != ".bin":
        raise ValueError("print job must have a .bin extension")
    count = 0
    with path.open("rb") as source, socket.create_connection((host, port), timeout=timeout) as connection:
        connection.settimeout(timeout)
        while chunk := source.read(64 * 1024):
            connection.sendall(chunk)
            count += len(chunk)
        connection.shutdown(socket.SHUT_WR)
    print(f"Transmitted {count} bytes to {host}:{port}.")
    print("Transmission succeeded. The printer did not confirm that the label printed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="printer IPv4 address or hostname")
    parser.add_argument("--timeout", type=float, default=5.0, help="network timeout in seconds")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status", help="read maintenance and configuration via HTTP")
    send_parser = commands.add_parser("send", help="transmit an existing Brother raster .bin job")
    send_parser.add_argument("job", type=Path)
    send_parser.add_argument("--port", type=int, default=9100)
    args = parser.parse_args()

    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.command == "send" and not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    try:
        if args.command == "status":
            return status(args.host, args.timeout)
        return send(args.host, args.port, args.timeout, args.job)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"printer_tool: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

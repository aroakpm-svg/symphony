#!/usr/bin/env python3
import os
import re
import sys
from urllib.parse import unquote, urlsplit


def invalid_url():
    raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL is invalid") from None


def decode_uri_component(value):
    if re.search(r"%(?![0-9A-Fa-f]{2})", value):
        invalid_url()
    return unquote(value)


def split_host_entries(hostspec):
    entries = []
    start = 0
    bracket_depth = 0
    for index, character in enumerate(hostspec):
        if character == "[":
            bracket_depth += 1
        elif character == "]":
            bracket_depth -= 1
            if bracket_depth < 0:
                invalid_url()
        elif character == "," and bracket_depth == 0:
            entries.append(hostspec[start:index])
            start = index + 1
    if bracket_depth != 0:
        invalid_url()
    entries.append(hostspec[start:])
    return entries


def parse_hosts(netloc):
    hostspec = netloc.rpartition("@")[2]
    hosts = []
    ports = []
    for entry in split_host_entries(hostspec):
        if not entry:
            invalid_url()
        try:
            parsed_host = urlsplit(f"postgresql://{entry}")
            host = parsed_host.hostname
            port = parsed_host.port
        except (UnicodeError, ValueError):
            invalid_url()
        if host is None or parsed_host.path or parsed_host.query or parsed_host.fragment:
            invalid_url()
        hosts.append(decode_uri_component(host))
        ports.append("" if port is None else str(port))
    return ",".join(hosts), ",".join(ports)


def parse_url(url):
    try:
        parsed = urlsplit(url)
        parameters = {}
        host, port = parse_hosts(parsed.netloc)
        parameters["host"] = host
        if port.strip(","):
            parameters["port"] = port
        if parsed.username is not None:
            parameters["user"] = decode_uri_component(parsed.username)
        if parsed.password is not None:
            parameters["password"] = decode_uri_component(parsed.password)
        if parsed.path and parsed.path != "/":
            parameters["dbname"] = decode_uri_component(parsed.path[1:])
    except (UnicodeError, ValueError):
        invalid_url()

    if parsed.scheme not in {"postgres", "postgresql"}:
        raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL must use postgres or postgresql")
    if parsed.fragment:
        raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL must not contain a fragment")

    for item in parsed.query.split("&"):
        if not item:
            continue
        raw_key, separator, raw_value = item.partition("=")
        key = decode_uri_component(raw_key)
        value = decode_uri_component(raw_value) if separator else ""
        if key == "ssl" and value == "true":
            key, value = "sslmode", "require"
        parameters[key] = value

    return parameters


url = os.environ["ARO169_POSTFLIGHT_DATABASE_URL"]
target = sys.argv[1]
parameters = parse_url(url)

if not any(key in {"host", "hostaddr"} for key in parameters):
    raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL must identify a host")
if not parameters.get("dbname"):
    raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL must identify a database")


def service_value(value):
    if any(character in value for character in "\r\n\0"):
        raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL contains an unsafe service value")
    if value != value.strip():
        raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL contains an unsafe service value")
    return value


with open(target, "w", encoding="utf-8", newline="\n") as service:
    service.write("[aro169_postflight]\n")
    for key, value in parameters.items():
        if not re.fullmatch(r"[a-z_]+", key):
            raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL contains an invalid parameter")
        service.write(f"{key}={service_value(value)}\n")

os.chmod(target, 0o600)

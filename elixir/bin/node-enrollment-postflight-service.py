#!/usr/bin/env python3
import os
import re
import sys
from urllib.parse import unquote, urlsplit


def parse_url(url):
    try:
        parsed = urlsplit(url)
        parameters = {}
        if parsed.hostname is not None:
            parameters["host"] = parsed.hostname
        if parsed.port is not None:
            parameters["port"] = str(parsed.port)
        if parsed.username is not None:
            parameters["user"] = unquote(parsed.username)
        if parsed.password is not None:
            parameters["password"] = unquote(parsed.password)
        if parsed.path and parsed.path != "/":
            parameters["dbname"] = unquote(parsed.path[1:])
    except (UnicodeError, ValueError):
        raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL is invalid") from None

    if parsed.scheme not in {"postgres", "postgresql"}:
        raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL must use postgres or postgresql")
    if parsed.fragment:
        raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL must not contain a fragment")

    for item in parsed.query.split("&"):
        if not item:
            continue
        raw_key, separator, raw_value = item.partition("=")
        key = unquote(raw_key)
        value = unquote(raw_value) if separator else ""
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
    return value


with open(target, "w", encoding="utf-8", newline="\n") as service:
    service.write("[aro169_postflight]\n")
    for key, value in parameters.items():
        if not re.fullmatch(r"[a-z_]+", key):
            raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL contains an invalid parameter")
        service.write(f"{key}={service_value(value)}\n")

os.chmod(target, 0o600)

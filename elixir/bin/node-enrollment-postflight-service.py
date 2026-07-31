#!/usr/bin/env python3
import os
import re
import sys
from urllib.parse import parse_qsl, unquote, urlsplit

url = os.environ["ARO169_POSTFLIGHT_DATABASE_URL"]
target = sys.argv[1]
parsed = urlsplit(url)

if parsed.scheme not in {"postgres", "postgresql"}:
    raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL must use postgres or postgresql")
if parsed.fragment:
    raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL must not contain a fragment")

parameters = []
if parsed.hostname is not None:
    parameters.append(("host", parsed.hostname))
if parsed.port is not None:
    parameters.append(("port", str(parsed.port)))
if parsed.username is not None:
    parameters.append(("user", unquote(parsed.username)))
if parsed.password is not None:
    parameters.append(("password", unquote(parsed.password)))
if parsed.path and parsed.path != "/":
    parameters.append(("dbname", unquote(parsed.path[1:])))
parameters.extend(parse_qsl(parsed.query, keep_blank_values=True))

if not any(key in {"host", "hostaddr"} for key, _value in parameters):
    raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL must identify a host")
if not any(key == "dbname" and value for key, value in parameters):
    raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL must identify a database")

def service_value(value):
    if any(character in value for character in "\r\n\0"):
        raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL contains an unsafe service value")
    return value

with open(target, "w", encoding="utf-8", newline="\n") as service:
    service.write("[aro169_postflight]\n")
    for key, value in parameters:
        if not re.fullmatch(r"[a-z_]+", key):
            raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL contains an invalid parameter")
        service.write(f"{key}={service_value(value)}\n")

os.chmod(target, 0o600)

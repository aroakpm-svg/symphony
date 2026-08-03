#!/usr/bin/env python3
import ctypes
import ctypes.util
import os
import sys


class ConninfoOption(ctypes.Structure):
    _fields_ = [
        ("keyword", ctypes.c_char_p),
        ("envvar", ctypes.c_char_p),
        ("compiled", ctypes.c_char_p),
        ("val", ctypes.c_char_p),
        ("label", ctypes.c_char_p),
        ("dispchar", ctypes.c_char_p),
        ("dispsize", ctypes.c_int),
    ]


def load_libpq():
    library_name = ctypes.util.find_library("pq")
    if not library_name:
        raise SystemExit("ARO-169 postflight cannot load libpq")
    library = ctypes.CDLL(library_name)
    library.PQconninfoParse.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_char_p)]
    library.PQconninfoParse.restype = ctypes.POINTER(ConninfoOption)
    library.PQconninfoFree.argtypes = [ctypes.POINTER(ConninfoOption)]
    library.PQfreemem.argtypes = [ctypes.c_void_p]
    return library


def parse_url(url):
    libpq = load_libpq()
    error = ctypes.c_char_p()
    options = libpq.PQconninfoParse(os.fsencode(url), ctypes.byref(error))
    if not options:
        if error:
            libpq.PQfreemem(error)
        raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL is invalid") from None

    parameters = {}
    try:
        index = 0
        while options[index].keyword:
            if options[index].val is not None:
                parameters[options[index].keyword] = options[index].val
            index += 1
    finally:
        libpq.PQconninfoFree(options)
    return parameters


url = os.environ["ARO169_POSTFLIGHT_DATABASE_URL"]
target = sys.argv[1]
parameters = parse_url(url)

# A service referenced by a URI cannot be nested inside the private service
# section used to keep credentials out of psql's argv. Flattening it would
# require resolving operator-owned service files and environment precedence,
# so fail closed before writing a misleading target.
if b"service" in parameters:
    raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL is invalid") from None

if not any(parameters.get(key) for key in {b"host", b"hostaddr"}):
    raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL must identify a host")
if not parameters.get(b"dbname"):
    raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL must identify a database")


def service_value(value):
    if any(character in value for character in b"\r\n\0"):
        raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL contains an unsafe service value")
    if value != value.strip():
        raise SystemExit("ARO169_POSTFLIGHT_DATABASE_URL contains an unsafe service value")
    return value


with open(target, "wb") as service:
    service.write(b"[aro169_postflight]\n")
    for key, value in parameters.items():
        service.write(key + b"=" + service_value(value) + b"\n")

os.chmod(target, 0o600)

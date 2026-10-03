# The network of tests/hosting_release_bundle.sh, loaded by every Python the
# test runs with this directory on PYTHONPATH: the GitHub API and the mirror
# of ops/hosting/build-release-catalog.py answer from the test's fixtures in
# HOSTING_TEST_NETWORK, every request is logged to its "requests" file, and
# no socket opens.
import io
import os
import socket
import urllib.error
import urllib.request
from pathlib import Path

NETWORK = Path(os.environ["HOSTING_TEST_NETWORK"])


def log(line):
    with open(NETWORK / "requests", "a", encoding="utf-8") as requests:
        requests.write(line + "\n")


def no_network(*args, **kwargs):
    log("socket")
    raise OSError("tests/hosting_release_bundle.sh has no network")


socket.create_connection = no_network
socket.getaddrinfo = no_network
socket.socket.connect = no_network


class Response(io.BytesIO):
    status = 200


# HOSTING_TEST_GITHUB_URL answers with github-releases.json; a HEAD request
# under HOSTING_TEST_BASE_URL finds a file under mirror/ or a 404.
def urlopen(request, *args, **kwargs):
    if not isinstance(request, urllib.request.Request):
        request = urllib.request.Request(request)
    method, url = request.get_method(), request.full_url
    log(f"{method} {url}")
    if method == "GET" and url == os.environ["HOSTING_TEST_GITHUB_URL"]:
        return Response((NETWORK / "github-releases.json").read_bytes())
    mirror = os.environ["HOSTING_TEST_BASE_URL"] + "/"
    if method == "HEAD" and url.startswith(mirror):
        if (NETWORK / "mirror" / url[len(mirror):]).is_file():
            return Response(b"")
        raise urllib.error.HTTPError(url, 404, "Not Found", None, None)
    log(f"unexpected {method} {url}")
    raise urllib.error.URLError(f"unexpected request: {method} {url}")


urllib.request.urlopen = urlopen

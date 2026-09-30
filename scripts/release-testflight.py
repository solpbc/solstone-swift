#!/usr/bin/env python3
"""Release an exported iOS build to an internal TestFlight group.

Given a build already uploaded to App Store Connect (via `xcrun altool
--upload-app`), this waits for Apple-side processing, clears the export-compliance
gate (usesNonExemptEncryption=false), attaches the build to the named internal
TestFlight group, and waits until it reaches IN_BETA_TESTING.

After a delivered upload, App Store Connect's status reads can fail or lag while
the build itself is fine: a list read can drop its included resources, the
build-detail endpoint can return 404, the group list can come back empty, and a
new build can take longer than expected to appear. None of those is a failed
release. This script retries reads within one bounded time budget and exits:

  0  released: the build is IN_BETA_TESTING and the group has it
  1  failed: Apple rejected the build, or the configuration is wrong
  3  unverified: status reads failed or lagged until the budget ran out; the
     upload is not in question, so check live state and re-run this script
     with --build-number rather than uploading again

Pure standard library plus `openssl` for the ES256 JWT — no third-party deps.
All account-specific values are passed as arguments; nothing is hardcoded.
"""
import argparse
import base64
import http.client
import json
import os
import plistlib
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


API_BASE = "https://api.appstoreconnect.apple.com"

EXIT_FAILED = 1
EXIT_UNVERIFIED = 3

# Transport retries per request, for timeouts, dropped connections, 429 and 5xx.
REQUEST_ATTEMPTS = 4
REQUEST_BACKOFF_SECONDS = 2

# App Store Connect tokens live at most 20 minutes; mint a new one well before.
TOKEN_LIFETIME_SECONDS = 1200
TOKEN_REFRESH_SECONDS = 900

POLL_SECONDS = 10


class ASCError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


class ASCUnverified(ASCError):
    """App Store Connect's status reads failed or lagged; the upload is not in question."""


class Deadline:
    def __init__(self, seconds):
        self.end = time.time() + seconds

    def remaining(self):
        return self.end - time.time()

    def expired(self):
        return self.remaining() <= 0


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def der_ecdsa_to_raw(signature):
    pos = 0
    if signature[pos] != 0x30:
        raise ASCError("OpenSSL returned a non-DER ECDSA signature")
    pos += 1

    length = signature[pos]
    pos += 1
    if length & 0x80:
        byte_count = length & 0x7F
        pos += byte_count

    if signature[pos] != 0x02:
        raise ASCError("OpenSSL DER signature is missing r")
    pos += 1
    r_length = signature[pos]
    pos += 1
    r = signature[pos : pos + r_length]
    pos += r_length

    if signature[pos] != 0x02:
        raise ASCError("OpenSSL DER signature is missing s")
    pos += 1
    s_length = signature[pos]
    pos += 1
    s = signature[pos : pos + s_length]

    return r.lstrip(b"\x00").rjust(32, b"\x00") + s.lstrip(b"\x00").rjust(32, b"\x00")


def make_jwt(key_id, issuer_id, key_path):
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + TOKEN_LIFETIME_SECONDS,
        "aud": "appstoreconnect-v1",
    }
    signing_input = (
        b64url(json.dumps(header, separators=(",", ":")).encode("utf-8"))
        + "."
        + b64url(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    ).encode("ascii")

    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        message = result.stderr.decode("utf-8", "replace").strip()
        raise ASCError(f"failed to sign App Store Connect JWT: {message}")

    return signing_input.decode("ascii") + "." + b64url(der_ecdsa_to_raw(result.stdout))


class AppStoreConnect:
    def __init__(self, token_factory, capture_dir=None):
        self.token_factory = token_factory
        self.token = None
        self.token_minted = 0
        self.capture_dir = capture_dir
        self.capture_count = 0

    def current_token(self, refresh=False):
        if refresh or self.token is None or time.time() - self.token_minted > TOKEN_REFRESH_SECONDS:
            self.token = self.token_factory()
            self.token_minted = time.time()
        return self.token

    def capture(self, method, url, status, payload):
        if not self.capture_dir:
            return
        self.capture_count += 1
        name = f"{self.capture_count:04d}-{method}.json"
        record = {"method": method, "url": url, "status": status, "body": payload}
        # Diagnostics only: a capture that cannot be written must never change
        # what the request itself reports.
        try:
            os.makedirs(self.capture_dir, exist_ok=True)
            with open(os.path.join(self.capture_dir, name), "w", encoding="utf-8") as handle:
                json.dump(record, handle, indent=2)
        except OSError as exc:
            print(f"warning: could not write {name}: {exc}", file=sys.stderr)

    def request(self, method, path, params=None, body=None):
        if path.startswith("https://"):
            url = path
        else:
            url = API_BASE + path
            if params:
                query = urllib.parse.urlencode(params, doseq=True, safe=",[]")
                url += "?" + query

        data = None
        if body is not None:
            data = json.dumps(body, separators=(",", ":")).encode("utf-8")

        # A POST is not retried on a transport fault: whether it landed is unknown,
        # and the caller decides what a repeat would mean.
        attempts = 1 if method == "POST" else REQUEST_ATTEMPTS
        refreshed = False
        attempt = 0
        while True:
            attempt += 1
            headers = {"Authorization": "Bearer " + self.current_token()}
            if data is not None:
                headers["Content-Type"] = "application/json"
            request = urllib.request.Request(url, data=data, headers=headers, method=method)
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    payload = response.read()
                    self.capture(method, url, response.status, payload.decode("utf-8", "replace"))
                    if response.status == 204 or not payload:
                        return None
                    return json.loads(payload)
            except urllib.error.HTTPError as exc:
                payload = exc.read().decode("utf-8", "replace")
                self.capture(method, url, exc.code, payload)
                if exc.code == 401 and not refreshed:
                    refreshed = True
                    attempt -= 1
                    self.current_token(refresh=True)
                    continue
                if (exc.code == 429 or exc.code >= 500) and attempt < attempts:
                    time.sleep(REQUEST_BACKOFF_SECONDS * 2 ** (attempt - 1))
                    continue
                error = ASCUnverified if exc.code == 429 or exc.code >= 500 else ASCError
                raise error(
                    f"{method} {path} failed with HTTP {exc.code}: {payload}",
                    status=exc.code,
                ) from exc
            except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as exc:
                self.capture(method, url, None, repr(exc))
                if attempt < attempts:
                    time.sleep(REQUEST_BACKOFF_SECONDS * 2 ** (attempt - 1))
                    continue
                raise ASCUnverified(f"{method} {path} failed: {exc}") from exc

    def get(self, path, params=None):
        return self.request("GET", path, params=params)

    def patch(self, path, body):
        return self.request("PATCH", path, body=body)

    def post(self, path, body):
        return self.request("POST", path, body=body)


def build_number_from_summary(path):
    with open(path, "rb") as handle:
        summary = plistlib.load(handle)

    for value in summary.values():
        if not isinstance(value, list):
            continue
        for entry in value:
            if isinstance(entry, dict) and "buildNumber" in entry:
                return str(entry["buildNumber"])

    raise ASCError(f"could not find buildNumber in {path}")


def included_by_type(payload):
    included = {}
    for item in payload.get("included", []):
        included.setdefault(item["type"], {})[item["id"]] = item
    return included


def relationship_ids(resource, name):
    data = resource.get("relationships", {}).get(name, {}).get("data")
    if data is None:
        return []
    if isinstance(data, dict):
        return [data["id"]]
    return [item["id"] for item in data]


def get_app(api, bundle_id):
    payload = api.get(
        "/v1/apps",
        {
            "filter[bundleId]": bundle_id,
            "fields[apps]": "name,bundleId",
            "limit": "10",
        },
    )
    apps = payload.get("data", [])
    if not apps:
        raise ASCError(f"no App Store Connect app found for bundle id {bundle_id}")
    if len(apps) > 1:
        raise ASCError(f"multiple App Store Connect apps found for bundle id {bundle_id}")
    return apps[0]


def get_beta_group(api, app_id, group_name, deadline):
    while True:
        payload = api.get(
            f"/v1/apps/{app_id}/betaGroups",
            {
                "fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds",
                "limit": "200",
            },
        )
        groups = (payload or {}).get("data") or []
        for group in groups:
            if group.get("attributes", {}).get("name") == group_name:
                return group
        if groups:
            names = [group.get("attributes", {}).get("name") for group in groups]
            raise ASCError(
                f"no TestFlight beta group named {group_name!r} found for app {app_id} "
                f"(groups: {names})"
            )
        # The named group has to exist for a release, so an empty list is a read
        # that has not caught up, not an answer.
        print("TestFlight groups: list read came back empty; retrying")
        if deadline.expired():
            raise ASCUnverified(
                f"the TestFlight group list for app {app_id} stayed empty, so "
                f"{group_name!r} could not be read"
            )
        time.sleep(POLL_SECONDS)


def fetch_build(api, app_id, build_number):
    payload = api.get(
        "/v1/builds",
        {
            "filter[app]": app_id,
            "fields[builds]": (
                "version,uploadedDate,processingState,buildAudienceType,expired,"
                "usesNonExemptEncryption,betaGroups,buildBetaDetail"
            ),
            "sort": "-uploadedDate",
            "limit": "200",
            "include": "betaGroups,buildBetaDetail",
            "fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds",
            "fields[buildBetaDetails]": (
                "internalBuildState,externalBuildState,autoNotifyEnabled"
            ),
        },
    )
    payload = payload or {}
    included = included_by_type(payload)
    for build in payload.get("data") or []:
        if str(build.get("attributes", {}).get("version")) == str(build_number):
            return build, included
    return None, included


def internal_build_state(api, build, included):
    """The build's internal TestFlight state, or None when it cannot be read yet."""
    detail_ids = relationship_ids(build, "buildBetaDetail")
    detail = included.get("buildBetaDetails", {}).get(detail_ids[0]) if detail_ids else None
    if detail:
        return detail.get("attributes", {}).get("internalBuildState")
    # A list read can drop its included resources while the build's own detail
    # endpoint still answers, so read it directly.
    try:
        payload = api.get(f"/v1/builds/{build['id']}/buildBetaDetail")
    except ASCError as exc:
        if exc.status == 404:
            return None
        raise
    return (((payload or {}).get("data") or {}).get("attributes") or {}).get(
        "internalBuildState"
    )


def group_names(build, included):
    names = []
    for group_id in relationship_ids(build, "betaGroups"):
        group = included.get("betaGroups", {}).get(group_id)
        if group:
            names.append(group.get("attributes", {}).get("name", group_id))
        else:
            names.append(group_id)
    return names


def build_has_group(build, included, group):
    # A group with access to all builds includes every build; its flag was read
    # live in this run, and a list read that drops included resources shows no
    # groups at all.
    if group.get("attributes", {}).get("hasAccessToAllBuilds") is True:
        return True
    return group["attributes"]["name"] in group_names(build, included)


def wait_for_build(api, app_id, build_number, deadline):
    while True:
        build, included = fetch_build(api, app_id, build_number)
        if build:
            state = build.get("attributes", {}).get("processingState")
            print(f"build {build_number}: processingState={state}")
            if state == "VALID":
                return build, included
            if state in {"FAILED", "INVALID"}:
                raise ASCError(f"build {build_number} processing failed with state {state}")
        else:
            print(f"build {build_number}: not visible in App Store Connect yet")
        if deadline.expired():
            if build:
                raise ASCUnverified(
                    f"build {build_number} was still {state} when the wait ran out"
                )
            raise ASCUnverified(
                f"build {build_number} was not visible in App Store Connect when the "
                "wait ran out; a delivered build can take longer than that to appear"
            )
        time.sleep(POLL_SECONDS)


def patch_export_compliance(api, build):
    build_id = build["id"]
    api.patch(
        f"/v1/builds/{build_id}",
        {
            "data": {
                "type": "builds",
                "id": build_id,
                "attributes": {"usesNonExemptEncryption": False},
            }
        },
    )
    print("export compliance: usesNonExemptEncryption=false")


def wait_for_export_compliance(api, app_id, build_number, deadline):
    internal_state = None
    while True:
        build, included = fetch_build(api, app_id, build_number)
        if build:
            internal_state = internal_build_state(api, build, included)
            uses_non_exempt = build.get("attributes", {}).get("usesNonExemptEncryption")
            print(
                f"build {build_number}: exportCompliance="
                f"usesNonExemptEncryption={uses_non_exempt}, "
                f"internalBuildState={internal_state}"
            )
            if (
                internal_state is not None
                and internal_state != "MISSING_EXPORT_COMPLIANCE"
                and uses_non_exempt is False
            ):
                return build, included
        if deadline.expired():
            raise ASCUnverified(
                f"build {build_number} export compliance could not be confirmed "
                f"(last internalBuildState={internal_state}) when the wait ran out"
            )
        time.sleep(POLL_SECONDS)


def attach_group(api, build, group):
    build_id = build["id"]
    group_id = group["id"]
    try:
        api.post(
            f"/v1/builds/{build_id}/relationships/betaGroups",
            {"data": [{"type": "betaGroups", "id": group_id}]},
        )
    except ASCError as exc:
        if exc.status == 409:
            print(f"TestFlight group: {group['attributes']['name']} is already related")
            return
        raise
    print(f"TestFlight group: added build to {group['attributes']['name']}")


def notify_testers(api, build):
    build_id = build["id"]
    api.post(
        "/v1/buildBetaNotifications",
        {
            "data": {
                "type": "buildBetaNotifications",
                "relationships": {
                    "build": {"data": {"type": "builds", "id": build_id}}
                },
            }
        },
    )
    print("TestFlight notification: requested")


def wait_for_internal_testing(api, app_id, build_number, group, deadline):
    internal_state = None
    while True:
        build, included = fetch_build(api, app_id, build_number)
        if build:
            internal_state = internal_build_state(api, build, included)
            names = group_names(build, included)
            print(
                f"build {build_number}: internalBuildState={internal_state}, "
                f"groups={names or ['none']}"
            )
            if internal_state == "PROCESSING_EXCEPTION":
                raise ASCError(f"build {build_number} hit a TestFlight processing exception")
            if internal_state == "IN_BETA_TESTING" and build_has_group(build, included, group):
                return build, included
        if deadline.expired():
            raise ASCUnverified(
                f"build {build_number} could not be confirmed IN_BETA_TESTING in "
                f"{group['attributes']['name']!r} (last internalBuildState="
                f"{internal_state}) when the wait ran out"
            )
        time.sleep(POLL_SECONDS)


def release(api, bundle_id, group_name, build_number, timeout, notify):
    deadline = Deadline(timeout)
    app = get_app(api, bundle_id)
    app_id = app["id"]
    group = get_beta_group(api, app_id, group_name, deadline)
    print(
        f"app={app['attributes']['name']} bundle={bundle_id} "
        f"build={build_number} group={group_name}"
    )

    build, included = wait_for_build(api, app_id, build_number, deadline)
    internal_state = internal_build_state(api, build, included)
    if (
        internal_state == "MISSING_EXPORT_COMPLIANCE"
        or build.get("attributes", {}).get("usesNonExemptEncryption") is None
    ):
        patch_export_compliance(api, build)
        build, included = wait_for_export_compliance(api, app_id, build_number, deadline)

    if group.get("attributes", {}).get("hasAccessToAllBuilds") is True:
        # Groups with "access to all builds" include every build automatically;
        # POSTing an explicit attach is both unnecessary and rejected (HTTP 422).
        print(f"TestFlight group: {group_name!r} has access to all builds — "
              f"build is included automatically (no attach needed)")
    elif group_name not in group_names(build, included):
        attach_group(api, build, group)
    else:
        print(f"TestFlight group: build already available to {group_name}")

    build, included = wait_for_internal_testing(api, app_id, build_number, group, deadline)

    if notify:
        notify_testers(api, build)

    print(f"released build {build_number} to TestFlight group {group_name}")


def main():
    parser = argparse.ArgumentParser(
        description="Release an exported iOS build to an internal TestFlight group."
    )
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--group-name", required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--key-path", required=True)
    parser.add_argument("--build-number")
    parser.add_argument("--summary", default="build/ipa-appstore/DistributionSummary.plist")
    parser.add_argument(
        "--timeout",
        type=int,
        default=1800,
        help="seconds to keep retrying App Store Connect reads after the upload",
    )
    parser.add_argument(
        "--capture-dir",
        help="write every App Store Connect response here, for diagnosing a read fault",
    )
    parser.add_argument("--notify", action="store_true")
    args = parser.parse_args()

    build_number = args.build_number or build_number_from_summary(args.summary)
    api = AppStoreConnect(
        lambda: make_jwt(args.key_id, args.issuer_id, args.key_path),
        capture_dir=(
            os.path.join(args.capture_dir, time.strftime("%Y%m%dT%H%M%S"))
            if args.capture_dir
            else None
        ),
    )
    try:
        release(api, args.bundle_id, args.group_name, build_number, args.timeout, args.notify)
    except ASCUnverified as exc:
        print(f"release-testflight: UNVERIFIED - {exc}", file=sys.stderr)
        print(
            "release-testflight: App Store Connect's status reads failed or lagged; "
            "this is not an upload failure. Do not run `make testflight` again, which "
            "rebuilds and uploads a second time. Check the build's live state, then "
            f"re-run this script with --build-number {build_number}.",
            file=sys.stderr,
        )
        return EXIT_UNVERIFIED
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ASCError as exc:
        print(f"release-testflight: FAIL - {exc}", file=sys.stderr)
        sys.exit(EXIT_FAILED)

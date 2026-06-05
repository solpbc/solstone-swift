#!/usr/bin/env python3
"""Release an exported iOS build to an internal TestFlight group.

Given a build already uploaded to App Store Connect (via `xcrun altool
--upload-app`), this waits for Apple-side processing, clears the export-compliance
gate (usesNonExemptEncryption=false), attaches the build to the named internal
TestFlight group, and waits until it reaches IN_BETA_TESTING.

Pure standard library plus `openssl` for the ES256 JWT — no third-party deps.
All account-specific values are passed as arguments; nothing is hardcoded.
"""
import argparse
import base64
import json
import plistlib
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


API_BASE = "https://api.appstoreconnect.apple.com"


class ASCError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


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
        "exp": now + 1200,
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
    def __init__(self, token):
        self.token = token

    def request(self, method, path, params=None, body=None):
        if path.startswith("https://"):
            url = path
        else:
            url = API_BASE + path
            if params:
                query = urllib.parse.urlencode(params, doseq=True, safe=",[]")
                url += "?" + query

        data = None
        headers = {"Authorization": "Bearer " + self.token}
        if body is not None:
            data = json.dumps(body, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"

        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                if response.status == 204:
                    return None
                payload = response.read()
                if not payload:
                    return None
                return json.loads(payload)
        except urllib.error.HTTPError as exc:
            payload = exc.read().decode("utf-8", "replace")
            raise ASCError(
                f"{method} {path} failed with HTTP {exc.code}: {payload}",
                status=exc.code,
            ) from exc

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
    data = resource.get("relationships", {}).get(name, {}).get("data", [])
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


def get_beta_group(api, app_id, group_name):
    payload = api.get(
        f"/v1/apps/{app_id}/betaGroups",
        {
            "fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds",
            "limit": "200",
        },
    )
    for group in payload.get("data", []):
        attributes = group.get("attributes", {})
        if attributes.get("name") == group_name:
            return group
    raise ASCError(f"no TestFlight beta group named {group_name!r} found for app {app_id}")


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
    included = included_by_type(payload)
    for build in payload.get("data", []):
        if str(build.get("attributes", {}).get("version")) == str(build_number):
            return build, included
    return None, included


def build_detail(build, included):
    detail_ids = relationship_ids(build, "buildBetaDetail")
    if not detail_ids:
        return {}
    detail = included.get("buildBetaDetails", {}).get(detail_ids[0])
    if not detail:
        return {}
    return detail.get("attributes", {})


def group_names(build, included):
    names = []
    for group_id in relationship_ids(build, "betaGroups"):
        group = included.get("betaGroups", {}).get(group_id)
        if group:
            names.append(group.get("attributes", {}).get("name", group_id))
        else:
            names.append(group_id)
    return names


def wait_for_build(api, app_id, build_number, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
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
        time.sleep(20)

    raise ASCError(f"timed out waiting for build {build_number} to become VALID")


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


def wait_for_export_compliance(api, app_id, build_number, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        build, included = fetch_build(api, app_id, build_number)
        if not build:
            time.sleep(10)
            continue

        detail = build_detail(build, included)
        internal_state = detail.get("internalBuildState")
        uses_non_exempt = build.get("attributes", {}).get("usesNonExemptEncryption")
        print(
            f"build {build_number}: exportCompliance="
            f"usesNonExemptEncryption={uses_non_exempt}, "
            f"internalBuildState={internal_state}"
        )
        if internal_state != "MISSING_EXPORT_COMPLIANCE" and uses_non_exempt is False:
            return build, included
        time.sleep(10)

    raise ASCError(f"timed out waiting for build {build_number} export compliance")


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


def wait_for_internal_testing(api, app_id, build_number, group_name, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        build, included = fetch_build(api, app_id, build_number)
        if not build:
            time.sleep(10)
            continue

        detail = build_detail(build, included)
        internal_state = detail.get("internalBuildState")
        names = group_names(build, included)
        print(
            f"build {build_number}: internalBuildState={internal_state}, "
            f"groups={names or ['none']}"
        )
        if internal_state == "IN_BETA_TESTING" and group_name in names:
            return build, included
        time.sleep(10)

    raise ASCError(
        f"timed out waiting for build {build_number} to enter IN_BETA_TESTING"
    )


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
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--notify", action="store_true")
    args = parser.parse_args()

    build_number = args.build_number or build_number_from_summary(args.summary)
    token = make_jwt(args.key_id, args.issuer_id, args.key_path)
    api = AppStoreConnect(token)

    app = get_app(api, args.bundle_id)
    app_id = app["id"]
    group = get_beta_group(api, app_id, args.group_name)
    print(
        f"app={app['attributes']['name']} bundle={args.bundle_id} "
        f"build={build_number} group={args.group_name}"
    )

    build, included = wait_for_build(api, app_id, build_number, args.timeout)
    detail = build_detail(build, included)
    attributes = build.get("attributes", {})
    if (
        detail.get("internalBuildState") == "MISSING_EXPORT_COMPLIANCE"
        or attributes.get("usesNonExemptEncryption") is None
    ):
        patch_export_compliance(api, build)
        build, included = wait_for_export_compliance(
            api, app_id, build_number, args.timeout
        )

    has_all_builds = bool(group.get("attributes", {}).get("hasAccessToAllBuilds"))
    names = group_names(build, included)
    if has_all_builds:
        # Groups with "access to all builds" include every build automatically;
        # POSTing an explicit attach is both unnecessary and rejected (HTTP 422).
        print(f"TestFlight group: {args.group_name!r} has access to all builds — "
              f"build is included automatically (no attach needed)")
    elif args.group_name not in names:
        attach_group(api, build, group)
    else:
        print(f"TestFlight group: build already available to {args.group_name}")

    build, included = wait_for_internal_testing(
        api, app_id, build_number, args.group_name, args.timeout
    )

    if args.notify:
        notify_testers(api, build)

    print(f"released build {build_number} to TestFlight group {args.group_name}")


if __name__ == "__main__":
    try:
        main()
    except ASCError as exc:
        print(f"release-testflight: FAIL - {exc}", file=sys.stderr)
        sys.exit(1)

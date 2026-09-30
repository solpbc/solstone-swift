#!/usr/bin/env python3
"""Tests for scripts/release-testflight.py against App Store Connect response shapes.

The healthy responses in test/fixtures/asc/ were captured from the live API. The
fault shapes are derived from them the way App Store Connect has actually
degraded after a delivered upload: a list read that drops its included
resources (relationship data null or empty, `included` empty), a build-detail
endpoint that returns 404, a group list that comes back empty, and a build
that takes longer than expected to appear.

Run: python3 test/test_release_testflight.py
"""
import copy
import importlib.util
import io
import json
import os
import socket
import unittest
import urllib.error
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "test", "fixtures", "asc")

spec = importlib.util.spec_from_file_location(
    "release_testflight", os.path.join(ROOT, "scripts", "release-testflight.py")
)
rt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rt)


def fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as handle:
        return json.load(handle)


APPS = fixture("apps.json")
GROUPS = fixture("beta-groups.json")
BUILDS = fixture("builds.json")
DETAIL = fixture("build-beta-detail.json")
NOT_FOUND = fixture("build-beta-detail-not-found.json")

APP_ID = APPS["data"][0]["id"]
BUILD = BUILDS["data"][0]
BUILD_ID = BUILD["id"]
BUILD_NUMBER = BUILD["attributes"]["version"]
GROUP_NAME = "solstone core"


class FakeClock:
    def __init__(self):
        self.now = 1_000_000.0

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def builds_payload(processing="VALID", internal="IN_BETA_TESTING", uses_non_exempt=False):
    payload = copy.deepcopy(BUILDS)
    build = payload["data"][0]
    build["attributes"]["processingState"] = processing
    build["attributes"]["usesNonExemptEncryption"] = uses_non_exempt
    for item in payload["included"]:
        if item["type"] == "buildBetaDetails":
            item["attributes"]["internalBuildState"] = internal
    return payload


def dropped_includes(payload):
    """The list-read fault: relationships present but empty, nothing included."""
    payload = copy.deepcopy(payload)
    for build in payload["data"]:
        build["relationships"]["buildBetaDetail"]["data"] = None
        build["relationships"]["betaGroups"]["data"] = []
    payload["included"] = []
    return payload


def not_visible():
    payload = copy.deepcopy(BUILDS)
    payload["data"] = []
    payload["included"] = []
    payload["meta"]["paging"]["total"] = 0
    return payload


def empty_groups():
    payload = copy.deepcopy(GROUPS)
    payload["data"] = []
    payload["meta"]["paging"]["total"] = 0
    return payload


def detail_payload(internal="IN_BETA_TESTING"):
    payload = copy.deepcopy(DETAIL)
    payload["data"]["attributes"]["internalBuildState"] = internal
    return payload


def not_found_error():
    return rt.ASCError(
        f"GET /v1/builds/{BUILD_ID}/buildBetaDetail failed with HTTP 404: "
        + json.dumps(NOT_FOUND),
        status=404,
    )


class FakeAPI:
    """Serves scripted responses per endpoint; the last one repeats."""

    def __init__(self, builds, groups=None, detail=None):
        self.scripts = {
            "builds": list(builds),
            "groups": list(groups or [GROUPS]),
            "detail": list(detail or [DETAIL]),
        }
        self.patches = []
        self.posts = []

    def next(self, key):
        script = self.scripts[key]
        response = script.pop(0) if len(script) > 1 else script[0]
        if isinstance(response, Exception):
            raise response
        return copy.deepcopy(response)

    def get(self, path, params=None):
        if path == "/v1/apps":
            return copy.deepcopy(APPS)
        if path == f"/v1/apps/{APP_ID}/betaGroups":
            return self.next("groups")
        if path == "/v1/builds":
            return self.next("builds")
        if path == f"/v1/builds/{BUILD_ID}/buildBetaDetail":
            return self.next("detail")
        raise AssertionError(f"unexpected GET {path}")

    def patch(self, path, body):
        self.patches.append(path)

    def post(self, path, body):
        self.posts.append(path)


def without_all_builds(groups):
    groups = copy.deepcopy(groups)
    for group in groups["data"]:
        if group["attributes"]["name"] == GROUP_NAME:
            group["attributes"]["hasAccessToAllBuilds"] = False
    return groups


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        patcher = mock.patch.object(rt, "time", self.clock)
        patcher.start()
        self.addCleanup(patcher.stop)

    def release(self, api, timeout=1800):
        with redirect_stdout(io.StringIO()):
            rt.release(api, "app.solstone.swift", GROUP_NAME, BUILD_NUMBER, timeout, False)

    def assert_unverified(self, api, timeout=1800):
        with self.assertRaises(rt.ASCUnverified):
            self.release(api, timeout)
        self.assertLessEqual(self.clock.now - 1_000_000.0, timeout + rt.POLL_SECONDS)

    def test_healthy_release_is_confirmed(self):
        self.release(FakeAPI([builds_payload()]))

    def test_export_compliance_is_cleared_then_confirmed(self):
        api = FakeAPI([
            builds_payload(processing="PROCESSING", internal="PROCESSING", uses_non_exempt=None),
            builds_payload(internal="MISSING_EXPORT_COMPLIANCE", uses_non_exempt=None),
            builds_payload(internal="IN_BETA_TESTING"),
        ])
        self.release(api)
        self.assertEqual(api.patches, [f"/v1/builds/{BUILD_ID}"])

    def test_dropped_includes_fall_back_to_the_detail_endpoint(self):
        self.release(FakeAPI([dropped_includes(builds_payload())]))

    def test_dropped_includes_and_detail_404_never_succeed(self):
        api = FakeAPI([dropped_includes(builds_payload())], detail=[not_found_error()])
        self.assert_unverified(api)

    def test_detail_404_that_recovers_is_confirmed(self):
        api = FakeAPI(
            [dropped_includes(builds_payload())],
            detail=[not_found_error()] * 5 + [DETAIL],
        )
        self.release(api)

    def test_empty_group_list_is_a_read_fault_not_a_missing_group(self):
        api = FakeAPI([builds_payload()], groups=[empty_groups()])
        self.assert_unverified(api)

    def test_empty_group_list_that_recovers_is_confirmed(self):
        api = FakeAPI([builds_payload()], groups=[empty_groups()] * 3 + [GROUPS])
        self.release(api)

    def test_group_missing_from_a_real_list_fails(self):
        groups = copy.deepcopy(GROUPS)
        groups["data"] = [g for g in groups["data"] if g["attributes"]["name"] != GROUP_NAME]
        api = FakeAPI([builds_payload()], groups=[groups])
        with self.assertRaises(rt.ASCError) as caught:
            self.release(api)
        self.assertNotIsInstance(caught.exception, rt.ASCUnverified)

    def test_slow_visibility_that_resolves_is_confirmed(self):
        # Longer than the old 900 s default: a delivered build has taken that long.
        polls = 1000 // rt.POLL_SECONDS
        self.release(FakeAPI([not_visible()] * polls + [builds_payload()]))

    def test_a_build_that_never_appears_is_unverified(self):
        self.assert_unverified(FakeAPI([not_visible()]), timeout=600)

    def test_processing_failure_fails(self):
        api = FakeAPI([builds_payload(processing="INVALID")])
        with self.assertRaises(rt.ASCError) as caught:
            self.release(api)
        self.assertNotIsInstance(caught.exception, rt.ASCUnverified)

    def test_processing_exception_fails(self):
        api = FakeAPI([builds_payload(internal="PROCESSING_EXCEPTION")])
        with self.assertRaises(rt.ASCError) as caught:
            self.release(api)
        self.assertNotIsInstance(caught.exception, rt.ASCUnverified)

    def test_in_beta_testing_without_the_group_is_never_success(self):
        # A group without access to all builds must show the build in its own
        # relationship; a dropped include cannot stand in for that.
        api = FakeAPI(
            [dropped_includes(builds_payload())],
            groups=[without_all_builds(GROUPS)],
        )
        self.assert_unverified(api)
        self.assertEqual(api.posts, [f"/v1/builds/{BUILD_ID}/relationships/betaGroups"])

    def test_every_fault_at_once_never_succeeds(self):
        api = FakeAPI(
            [not_visible()] * 3 + [dropped_includes(builds_payload())],
            groups=[GROUPS] + [empty_groups()],
            detail=[not_found_error()],
        )
        self.assert_unverified(api)


class FakeResponse:
    def __init__(self, payload, status=200):
        self.status = status
        self.payload = json.dumps(payload).encode("utf-8")

    def read(self):
        return self.payload

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def http_error(code, payload=NOT_FOUND):
    return urllib.error.HTTPError(
        "https://api.appstoreconnect.apple.com/v1/builds",
        code,
        "error",
        {},
        io.BytesIO(json.dumps(payload).encode("utf-8")),
    )


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        patcher = mock.patch.object(rt, "time", self.clock)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.tokens = []

    def api(self):
        def factory():
            self.tokens.append(f"token-{len(self.tokens)}")
            return self.tokens[-1]

        return rt.AppStoreConnect(factory)

    def urlopen(self, *outcomes):
        outcomes = list(outcomes)
        seen = []

        def fake(request, timeout):
            seen.append(request)
            outcome = outcomes.pop(0)
            if isinstance(outcome, Exception):
                raise outcome
            return outcome

        return mock.patch.object(rt.urllib.request, "urlopen", fake), seen

    def test_timeouts_and_server_errors_are_retried(self):
        patcher, seen = self.urlopen(
            socket.timeout("The read operation timed out"),
            http_error(503),
            FakeResponse(GROUPS),
        )
        with patcher:
            self.assertEqual(self.api().get("/v1/apps/x/betaGroups"), GROUPS)
        self.assertEqual(len(seen), 3)

    def test_persistent_transport_failure_is_unverified(self):
        errors = [urllib.error.URLError("unreachable")] * rt.REQUEST_ATTEMPTS
        patcher, seen = self.urlopen(*errors)
        with patcher, self.assertRaises(rt.ASCUnverified):
            self.api().get("/v1/builds")
        self.assertEqual(len(seen), rt.REQUEST_ATTEMPTS)

    def test_not_found_is_returned_to_the_caller_without_retry(self):
        patcher, seen = self.urlopen(http_error(404))
        with patcher, self.assertRaises(rt.ASCError) as caught:
            self.api().get(f"/v1/builds/{BUILD_ID}/buildBetaDetail")
        self.assertEqual(caught.exception.status, 404)
        self.assertNotIsInstance(caught.exception, rt.ASCUnverified)
        self.assertEqual(len(seen), 1)

    def test_an_expired_token_is_refreshed_once(self):
        patcher, seen = self.urlopen(http_error(401), FakeResponse(APPS))
        with patcher:
            self.assertEqual(self.api().get("/v1/apps"), APPS)
        self.assertEqual(
            [r.get_header("Authorization") for r in seen],
            ["Bearer token-0", "Bearer token-1"],
        )

    def test_a_long_wait_mints_a_new_token_before_it_expires(self):
        api = self.api()
        patcher, seen = self.urlopen(FakeResponse(APPS), FakeResponse(APPS))
        with patcher:
            api.get("/v1/apps")
            self.clock.sleep(rt.TOKEN_REFRESH_SECONDS + 1)
            api.get("/v1/apps")
        self.assertEqual(len(self.tokens), 2)

    def test_an_unwritable_capture_does_not_turn_a_success_into_a_fault(self):
        api = rt.AppStoreConnect(lambda: "token", capture_dir="/dev/null/asc-reads")
        patcher, seen = self.urlopen(FakeResponse(APPS))
        with patcher, redirect_stderr(io.StringIO()):
            self.assertEqual(api.post("/v1/buildBetaNotifications", {"data": {}}), APPS)
        self.assertEqual(len(seen), 1)

    def test_a_post_is_not_repeated_after_a_transport_fault(self):
        patcher, seen = self.urlopen(socket.timeout("timed out"))
        with patcher, self.assertRaises(rt.ASCUnverified):
            self.api().post("/v1/builds/x/relationships/betaGroups", {"data": []})
        self.assertEqual(len(seen), 1)


class ExitCodeTests(unittest.TestCase):
    def run_main(self, error):
        argv = [
            "release-testflight.py", "--bundle-id", "b", "--group-name", GROUP_NAME,
            "--key-id", "k", "--issuer-id", "i", "--key-path", "/nonexistent",
            "--build-number", BUILD_NUMBER,
        ]
        stderr = io.StringIO()
        with mock.patch.object(rt.sys, "argv", argv), \
                mock.patch.object(rt, "release", side_effect=error), \
                redirect_stderr(stderr):
            code = rt.main()
        return code, stderr.getvalue()

    def test_unverified_exits_3_and_says_not_to_upload_again(self):
        code, stderr = self.run_main(rt.ASCUnverified("reads lagged"))
        self.assertEqual(code, rt.EXIT_UNVERIFIED)
        self.assertIn("not an upload failure", stderr)
        self.assertIn(f"--build-number {BUILD_NUMBER}", stderr)

    def test_success_exits_0(self):
        code, _ = self.run_main(None)
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()

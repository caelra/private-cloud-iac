import pytest

import trigger


class ImageNotFound(Exception):
    pass


class ClientError(Exception):
    """Mimics botocore's ClientError shape without needing botocore."""

    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code}}


class FakeEcr:
    class exceptions:
        ImageNotFoundException = ImageNotFound

    def __init__(self, exists, errors=()):
        self.exists = exists
        self.errors = list(errors)

    def describe_images(self, repositoryName, imageIds):
        if self.errors:
            raise self.errors.pop(0)
        if not self.exists:
            raise ImageNotFound()
        return {"imageDetails": [{}]}


class FakeCodeBuild:
    """Each entry is a build status, or a (status, failed_phase) tuple."""

    def __init__(self, statuses):
        self.statuses = list(statuses)
        self.started = 0

    def start_build(self, projectName):
        self.started += 1
        return {"build": {"id": f"{projectName}:{self.started}"}}

    def batch_get_builds(self, ids):
        entry = self.statuses.pop(0)
        status, failed_phase = entry if isinstance(entry, tuple) else (entry, None)
        phases = [{"phaseType": "SUBMITTED", "phaseStatus": "SUCCEEDED"}]
        if failed_phase:
            phases.append({"phaseType": failed_phase, "phaseStatus": "FAILED"})
        return {"builds": [{"id": ids[0], "buildStatus": status, "phases": phases}]}


class FakeContext:
    def __init__(self, remaining_ms=900_000):
        self.remaining_ms = remaining_ms

    def get_remaining_time_in_millis(self):
        return self.remaining_ms


EVENT = {"project": "proj", "repository": "repo", "image_tag": "abc123"}


def test_skips_when_image_already_exists():
    cb = FakeCodeBuild([])
    result = trigger.handler(EVENT, FakeContext(), cb=cb, ecr=FakeEcr(exists=True), sleep=lambda s: None)
    assert result == {"status": "SKIPPED", "image_tag": "abc123"}
    assert cb.started == 0


def test_starts_build_and_waits_for_success():
    cb = FakeCodeBuild(["IN_PROGRESS", "IN_PROGRESS", "SUCCEEDED"])
    result = trigger.handler(EVENT, FakeContext(), cb=cb, ecr=FakeEcr(exists=False), sleep=lambda s: None)
    assert result == {"status": "SUCCEEDED", "image_tag": "abc123", "build_id": "proj:1"}
    assert cb.started == 1


def test_failed_build_raises():
    cb = FakeCodeBuild(["IN_PROGRESS", "FAILED"])
    with pytest.raises(RuntimeError, match="FAILED"):
        trigger.handler(EVENT, FakeContext(), cb=cb, ecr=FakeEcr(exists=False), sleep=lambda s: None)


def test_times_out_before_lambda_deadline():
    cb = FakeCodeBuild(["IN_PROGRESS"])
    with pytest.raises(TimeoutError):
        trigger.handler(EVENT, FakeContext(remaining_ms=1_000), cb=cb, ecr=FakeEcr(exists=False), sleep=lambda s: None)
    assert cb.started == 1


def test_retries_access_denied_while_iam_propagates():
    cb = FakeCodeBuild(["SUCCEEDED"])
    ecr = FakeEcr(exists=False, errors=[ClientError("AccessDeniedException"), ClientError("AccessDeniedException")])
    slept = []
    result = trigger.handler(EVENT, FakeContext(), cb=cb, ecr=ecr, sleep=slept.append)
    assert result["status"] == "SUCCEEDED"
    assert cb.started == 1
    assert slept[:2] == [5, 10]


def test_persistent_access_denied_raises():
    cb = FakeCodeBuild([])
    ecr = FakeEcr(exists=False, errors=[ClientError("AccessDeniedException")] * 20)
    slept = []
    with pytest.raises(ClientError):
        trigger.handler(EVENT, FakeContext(), cb=cb, ecr=ecr, sleep=slept.append)
    assert cb.started == 0
    assert slept == [5, 10, 15, 20, 25]


def test_restarts_once_after_early_phase_failure():
    cb = FakeCodeBuild([("FAILED", "PROVISIONING"), "IN_PROGRESS", "SUCCEEDED"])
    result = trigger.handler(EVENT, FakeContext(), cb=cb, ecr=FakeEcr(exists=False), sleep=lambda s: None)
    assert result == {"status": "SUCCEEDED", "image_tag": "abc123", "build_id": "proj:2"}
    assert cb.started == 2


def test_second_early_failure_raises():
    cb = FakeCodeBuild([("FAILED", "DOWNLOAD_SOURCE"), ("FAULT", "PRE_BUILD")])
    with pytest.raises(RuntimeError, match="FAULT"):
        trigger.handler(EVENT, FakeContext(), cb=cb, ecr=FakeEcr(exists=False), sleep=lambda s: None)
    assert cb.started == 2


def test_build_phase_failure_raises_without_restart():
    cb = FakeCodeBuild([("FAILED", "BUILD")])
    with pytest.raises(RuntimeError, match="FAILED"):
        trigger.handler(EVENT, FakeContext(), cb=cb, ecr=FakeEcr(exists=False), sleep=lambda s: None)
    assert cb.started == 1

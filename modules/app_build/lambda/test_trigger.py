import pytest

import trigger


class ImageNotFound(Exception):
    pass


class FakeEcr:
    class exceptions:
        ImageNotFoundException = ImageNotFound

    def __init__(self, exists):
        self.exists = exists

    def describe_images(self, repositoryName, imageIds):
        if not self.exists:
            raise ImageNotFound()
        return {"imageDetails": [{}]}


class FakeCodeBuild:
    def __init__(self, statuses):
        self.statuses = list(statuses)
        self.started = 0

    def start_build(self, projectName):
        self.started += 1
        return {"build": {"id": f"{projectName}:1"}}

    def batch_get_builds(self, ids):
        return {"builds": [{"id": ids[0], "buildStatus": self.statuses.pop(0)}]}


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

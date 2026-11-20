"""Start a CodeBuild build and wait for it, so `terraform apply` blocks until
the image exists and fails if the build fails."""

import time

POLL_SECONDS = 10
SAFETY_MARGIN_MS = 15_000
ACCESS_DENIED_ATTEMPTS = 6
ACCESS_DENIED_CODES = {"AccessDeniedException", "AccessDenied", "UnauthorizedOperation"}
# A failure in these phases means nothing was pushed, so the build can be
# started again without colliding on the immutable tag.
EARLY_PHASES = {"PROVISIONING", "DOWNLOAD_SOURCE", "INSTALL", "PRE_BUILD"}
FAILED_PHASE_STATUSES = {"FAILED", "FAULT", "TIMED_OUT", "CLIENT_ERROR"}


def _is_access_denied(error):
    return getattr(error, "response", {}).get("Error", {}).get("Code") in ACCESS_DENIED_CODES


def _retry_access_denied(call, sleep):
    """On a clean first apply this Lambda runs seconds after its IAM policies
    are created, so AccessDenied can just mean they have not propagated yet."""
    for attempt in range(1, ACCESS_DENIED_ATTEMPTS + 1):
        try:
            return call()
        except Exception as e:
            if not _is_access_denied(e) or attempt == ACCESS_DENIED_ATTEMPTS:
                raise
            sleep(5 * attempt)


def _failed_early(build):
    return any(
        phase.get("phaseType") in EARLY_PHASES and phase.get("phaseStatus") in FAILED_PHASE_STATUSES
        for phase in build.get("phases", [])
    )


def handler(event, context, cb=None, ecr=None, sleep=time.sleep):
    if cb is None or ecr is None:
        import boto3

        cb = cb or boto3.client("codebuild")
        ecr = ecr or boto3.client("ecr")

    project = event["project"]
    repository = event["repository"]
    image_tag = event["image_tag"]

    # Tags are immutable and derived from the source hash, so an existing tag
    # means this exact source was already built.
    try:
        _retry_access_denied(
            lambda: ecr.describe_images(repositoryName=repository, imageIds=[{"imageTag": image_tag}]),
            sleep,
        )
        return {"status": "SKIPPED", "image_tag": image_tag}
    except ecr.exceptions.ImageNotFoundException:
        pass

    restarted = False
    build_id = _retry_access_denied(lambda: cb.start_build(projectName=project), sleep)["build"]["id"]

    while context.get_remaining_time_in_millis() > SAFETY_MARGIN_MS:
        build = cb.batch_get_builds(ids=[build_id])["builds"][0]
        status = build["buildStatus"]
        if status == "SUCCEEDED":
            return {"status": "SUCCEEDED", "image_tag": image_tag, "build_id": build_id}
        if status in ("FAILED", "FAULT") and not restarted and _failed_early(build):
            restarted = True
            build_id = _retry_access_denied(lambda: cb.start_build(projectName=project), sleep)["build"]["id"]
            continue
        if status != "IN_PROGRESS":
            raise RuntimeError(f"CodeBuild build {build_id} ended with status {status}")
        sleep(POLL_SECONDS)

    raise TimeoutError(f"CodeBuild build {build_id} still running at Lambda deadline")

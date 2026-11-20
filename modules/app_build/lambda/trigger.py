"""Start a CodeBuild build and wait for it, so `terraform apply` blocks until
the image exists and fails if the build fails."""

import time

POLL_SECONDS = 10
SAFETY_MARGIN_MS = 15_000


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
        ecr.describe_images(repositoryName=repository, imageIds=[{"imageTag": image_tag}])
        return {"status": "SKIPPED", "image_tag": image_tag}
    except ecr.exceptions.ImageNotFoundException:
        pass

    build_id = cb.start_build(projectName=project)["build"]["id"]

    while context.get_remaining_time_in_millis() > SAFETY_MARGIN_MS:
        status = cb.batch_get_builds(ids=[build_id])["builds"][0]["buildStatus"]
        if status == "SUCCEEDED":
            return {"status": "SUCCEEDED", "image_tag": image_tag, "build_id": build_id}
        if status != "IN_PROGRESS":
            raise RuntimeError(f"CodeBuild build {build_id} ended with status {status}")
        sleep(POLL_SECONDS)

    raise TimeoutError(f"CodeBuild build {build_id} still running at Lambda deadline")

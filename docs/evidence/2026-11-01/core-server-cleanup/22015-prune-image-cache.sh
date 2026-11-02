#!/usr/bin/env bash
set -euo pipefail
unset -f cd 2>/dev/null || true
[[ $(hostname) == dev-ai-amd ]]
expected_image=sha256:40591db1f39677f5fce9260534e2deed7b89c88d597c36a72772a9fbe01482f4
before_id=$(docker inspect --format '{{.Id}}' sputnik-remote-core)
before_pid=$(docker inspect --format '{{.State.Pid}}' sputnik-remote-core)
[[ $(docker inspect --format '{{.Image}}' sputnik-remote-core) == "$expected_image" ]]
[[ $(docker inspect --format '{{.State.Health.Status}}' sputnik-remote-core) == healthy ]]
# These exact records are immutable references shared with the working image.
# Delete cache references only; do not remove or rebuild the runtime image.
for cache_id in 0rfmssvw3l2kxk9y1mimm2sc3 rmstb3qjpduphi9tf7axwq3s3 qcbg5ra67uu0mh496zdzpbei6 wk8emrd9h5cso00ajw1wzt7z9 6vqeamio4e90474dol1tku3f6 jx3vx3bq0qgz6os3445fj1pgw h3ff58102scz45a971u8s7tgt 5qynxt8gy25bjmjstl3zkeadq; do
  printf 'REMOVE_CORE_IMAGE_CACHE_REFERENCE %s\n' "$cache_id"
  docker buildx prune --all --force --filter "id=$cache_id"
done
[[ $(docker inspect --format '{{.Id}}' sputnik-remote-core) == "$before_id" ]]
[[ $(docker inspect --format '{{.State.Pid}}' sputnik-remote-core) == "$before_pid" ]]
[[ $(docker inspect --format '{{.Image}}' sputnik-remote-core) == "$expected_image" ]]
[[ $(docker inspect --format '{{.State.Health.Status}}' sputnik-remote-core) == healthy ]]
printf 'PASS_RUNTIME_IMAGE_CONTAINER_AND_PID_UNCHANGED\n'
docker buildx du --verbose

# Docker Cleanup Design

## Goal

Add a dedicated Docker section that explains Docker disk usage and lets the user remove explicitly reviewed resources without broad prune commands.

## Scope

The first version scans and manages four resource types:

- stopped containers;
- images not referenced by any container;
- reclaimable BuildKit cache records;
- dangling volumes that are not referenced by any container.

Running containers, images referenced by any container, active build-cache records, networks, and Docker's virtual-machine files are excluded.

## Safety contract

Docker-managed resources cannot be moved to the macOS Trash. The user approved a narrow exception to the repository's Trash-only rule for this subsystem. The exception applies only to Docker CLI commands constructed by `DockerClient` from resource IDs returned by the same daemon scan.

- Never run `docker system prune`, `docker container prune`, `docker image prune`, or `docker volume prune`.
- Never pass `--force` to container, image, or volume removal.
- Delete containers with `docker container rm <exact-id>`.
- Delete images with `docker image rm <exact-id>` only after proving no inspected container references the image ID.
- Delete volumes with `docker volume rm <exact-name>` only when `docker volume ls --filter dangling=true` returned the name.
- Pin the Docker context name and endpoint plus the Buildx builder identity in the immutable scan snapshot. Every command uses the pinned context, and both identities are revalidated before deletion.
- Delete build cache with `docker buildx prune --builder <builder> --force --filter id=^<escaped-id>$ --filter until=168h` only for records reported as reclaimable. The anchored filter prevents partial ID matches, the age filter rechecks staleness at deletion time, and `--force` only suppresses the interactive prompt.
- Capture an immutable resource snapshot and show every name, ID, size when known, and reason before running any command.
- Volumes are never preselected and require a separate warning confirmation.
- Stopped containers and unused tagged images are never preselected.
- Dangling images and old reclaimable build cache are preselected because they are rebuildable.
- A failed removal remains in the result list with its error; successful resources disappear only after the command succeeds.
- Re-scan after every cleanup to reflect Docker's actual state.

## Architecture

`DockerCommandRunner` owns `Foundation.Process`, locates the Docker executable in known GUI-safe paths, captures stdout/stderr, and returns a structured result. `DockerClient` is an actor that scans with read-only commands, parses inspect JSON, classifies resources, and performs exact-ID removal. Tests inject a command closure at the `DockerClient` boundary, while parser tests use full Docker-shaped JSON fixtures.

`DockerCleanupViewModel` is `@Observable @MainActor`. It serializes scan and cleanup operations, maintains selection, enforces the separate volume confirmation flow, and exposes immutable cleanup snapshots. `DockerCleanupView` is a new `AppTab` with status, totals, category sections, checkboxes, risk labels, and confirmation sheets.

## Discovery and classification

The scan resolves `docker context show`, records its endpoint, and prefixes daemon commands with `--context <name>` before running `docker version --format {{json .Server}}`. A missing executable produces an installation state; a command failure produces a daemon-unavailable state with a Docker Desktop launch action.

When the daemon is available:

1. `docker container ls --all --quiet --no-trunc` returns container IDs.
2. `docker container inspect --size <ids...>` returns state, image IDs, writable-layer sizes, names, and timestamps.
3. `docker image ls --all --quiet --no-trunc` returns image IDs.
4. `docker image inspect <ids...>` returns tags, creation time, and byte size.
5. Images whose normalized ID is absent from all inspected containers are unused. Untagged unused images are dangling and selected by default; tagged unused images require review.
6. `docker volume ls --filter dangling=true --quiet` returns unused volume names; `docker volume inspect <names...>` adds creation time and labels.
7. `docker buildx ls --format json` captures the current builder and its worker IDs. `docker buildx du --builder <name> --format json` returns its cache records. Only reclaimable records last accessed at least seven days ago are shown and selected.

An empty ID list skips its inspect command.

## User experience

The rail adds “Docker” with a shipping-container icon. The section handles four primary states: Docker not installed, Docker Desktop stopped, scanning, and results.

Results show reclaimable total, count, search, and sections for cache, images, containers, and volumes. Each row explains why it is listed. Running resources never appear. The primary cleanup button opens a scrollable confirmation containing the exact snapshot. If that snapshot includes volumes, a second warning must be accepted before execution.

The existing license policy applies at cleanup admission and records one clean only when at least one command succeeds. Docker cleanup has its own busy state and cannot overlap another Docker scan or cleanup.

## Error handling

Nonzero Docker exit status is presented using stderr without exposing environment variables or Docker configuration contents. Every nonzero removal result remains a failure, including missing-resource and missing-builder errors. Unsupported Buildx output hides build-cache candidates while preserving containers, images, and volumes.

## Validation

- Unit tests cover process cancellation and large output, inspect parsing, referenced-image exclusion, default selection, cache age/reclaimability, exact command construction, context and builder drift, volume safeguards, and busy admission.
- Existing tests remain green.
- Debug and Release builds pass with code signing disabled.
- Manual UI QA covers a real populated Docker environment, search, immutable preview, and the typed volume warning without invoking deletion. CLI-missing and daemon-unavailable states are covered by injected tests.

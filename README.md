<div align="center">
  <img align="center" width="320" src="assets/logos/container-tagger-orb-512px.png" alt="Container Tagger Orb">
  <h1>CircleCI Container Tagger Orb</h1>
  <i>An orb for automatically tagging container images within CircleCI.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/container-tagger-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/container-tagger-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/container-tagger-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/container-tagger-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/container-tagger-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

This is an orb for automatically tagging container images within your CircleCI pipeline using semantic versioning, allowing you to release multiple tags simultaneously.

<div align="center">
    <img align="center" width="500" src="assets/tagger-concept-v2.png" alt="Container Tagger Concept">
</div>

## Motivation
When releasing new versions of your software, it's often desirable to create multiple tags for a given container image. For example, instead of releasing `:2.5.2` as a single tag, you will often want to release several other tags, to include:
- `:latest` - the latest and greatest version of your software
- `:2.5.2` - the actual version number
- `:2.5` - latest patch in the 2.5 series
- `:2` - latest release in the 2 series

While this may seem straightforward, it’s not appropriate to do this for every release. For instance, if you later release an emergency security patch for the older 2.4 series of your software, you wouldn’t want to tag that image with the `:latest` tag -- or even the `:2` tag, for that matter. The new image should only receive two tags:
- `:2.4.8` - the actual version number
- `:2.4` - latest patch in the 2.4 series

Some projects may also choose to maintain an `:edge` tag that contains the latest successful merges into the trunk, which have not yet received an official tag. This allows you to easily pull down pre-release images before the next official release. This is useful for deploying images to internal staging environments.

This orb will handle these edge cases and more.

## Assumptions and Strategy

This orb requires that your git tags follow semantic versioning. Examples of valid tags include:
- `v2.5.2`
- `v2.5.3-rc1`
- `v2.5.3-rc`
- `v2.5.3-rc.1`
- `v2.5.3-alpha1`
- `v2.5.3-beta4`

`alpha` and `beta` accept the same suffix shapes as `rc`. A tag pipeline whose git tag is not one of these forms fails, instead of publishing that release as `dev-<sha>` or `edge`. The same forms apply to the `git_tag` parameter described below.

This orb functions by reading git tags to determine which versions already exist. A final release compares the tag being built with tags in the checkout and with tag names from the checkout's remote. `git ls-remote` supplies those names without downloading tagged commits. An HTTP or HTTPS remote URL that embeds credentials is read without putting those credentials on the git transport command line; the scheme is matched case-insensitively. A password embedded in any other kind of remote URL, such as `ftp://` or `ssh://`, fails the release, because it cannot be kept off that transport's command line. An `@` in the repository path stays part of the path. A URL that contains only a username still uses configured credential helpers for its password, and falls back to an empty password, as git does for `https://TOKEN@host`. That read uses the URL without its userinfo, so `http.<url>.*` settings scoped to a username (`http.https://alice@host.sslCAInfo`) do not apply to it; scope them to the host instead. An `insteadOf` rule that injects credentials and whose value is the remote's entire URL, such as `url."https://TOKEN@host/repo.git".insteadOf "https://host/repo.git"`, fails the release, because the orb cannot override it without the credentials reaching the transport; use a host-level rule (`insteadOf "https://host/"`) instead. `origin` is used when it exists; otherwise the sole remote is used. Several remotes and no `origin` is a failure, so the orb does not guess which remote is authoritative. A shallow checkout whose local `git tag` output contains only the current tag still sees older tags on the remote. If that remote list cannot be read, the release fails, so an older tag cannot take the newest floating tags. A checkout with no remote uses local tags, and an empty list is a first release that still publishes the floating tags. Pre-releases leave floating tags unchanged and skip this check.

Any merge into `master`, `main`, or `develop` will result in an `:edge` tag being created, provided your container build job is within a workflow that builds on non-tagged commits.

Running a Golang monorepo where you're creating tags such as `microservices/authservice/v1.0.5`? No problem. This is supported as well. Pass the git tag namespace as `git_tag_prefix: microservices/authservice` to `generate_tags` and `export_tag`. The prefix only selects git tags; the container tags never include it. `microservices/authservice/v1.0.5` produces `:1.0.5`, plus `:1.0`, `:1`, and `:latest` when it is the newest release in that namespace.

Only tags in the same namespace are compared when choosing `:latest`, `:X`, and `:X.Y`. With `git_tag_prefix: microservices/authservice`, that is exactly `microservices/authservice/vX.Y.Z`; tags such as `microservices/authservice-legacy/v9.0.0` or `microservices/authservice/beta/v9.0.0` are ignored. Without a `git_tag_prefix`, it is `vX.Y.Z` with no slash, so tags such as `zeta/v9.9.9`, `wip-v5.0.0`, or `opengee-v5.3.9` are ignored.

### Releasing without a tag pipeline: `git_tag`

By default the release identity is `CIRCLE_TAG`, and when that is empty, `CIRCLE_BRANCH` selects `:edge` or a `dev-<sha>` tag. Some release workflows do not run from a tag pipeline, for example a protected `release-execution/<tag>` branch that carries its own validated release tag. Pass that tag to both `generate_tags` and `export_tag` as `git_tag`:

```yaml
- tagger/export_tag:
    git_tag: ${RELEASE_TAG}
- tagger/generate_tags:
    git_tag: ${RELEASE_TAG}
```

When `git_tag` is set:
- It is the only release identity. `CIRCLE_BRANCH` is not consulted, so a release whose pipeline runs on `main` does not also publish `:edge` or `main-<sha>`.
- It must be a supported release tag, using the same forms listed above. Anything else fails the step. There is no fallback to `CIRCLE_TAG`, `:edge`, `main-<sha>`, or `dev-<sha>`.
- If `CIRCLE_TAG` is also set, the two must be identical.
- With a `git_tag_prefix`, it must be the full tag name, `<git_tag_prefix>/vX.Y.Z`. A bare `vX.Y.Z` or another prefix fails, because those are different git tags. (`CIRCLE_TAG` still also accepts a bare `vX.Y.Z` with a `git_tag_prefix`, for compatibility.)
- A value that expands to an empty string, such as `${RELEASE_TAG}` when that variable is unset, fails the step instead of falling back. To keep the default behaviour, leave the parameter empty, for example with a pipeline parameter that defaults to `""`.
- A final release still compares against the repository's existing tags, from the checkout and its remote, to choose `:latest`, `:X`, and `:X.Y`, so a branch checkout that lacks some release tags does not need `git fetch --tags` first.

Both commands log which identity they used: `git_tag`, `CIRCLE_TAG`, or the branch.

## Commands

Relative paths are resolved against the working directory, and a leading `~/` in a path means `$HOME`.

### `generate_tags`

Writes the container tags for this build to a file, one per line.

| Parameter | Default | Description |
| --- | --- | --- |
| `tags_file` | `tags.txt` | File to write the tags to. It is created or truncated. |
| `git_tag_prefix` | `""` | Git tag namespace for monorepos, without a trailing slash: `svc/auth` matches git tags like `svc/auth/v1.2.3`. The container tags never include it. |
| `git_tag` | `""` | Git tag of the release, used instead of `CIRCLE_TAG`. See [Releasing without a tag pipeline](#releasing-without-a-tag-pipeline-git_tag). |

### `tag` and `push`

`tag` applies every tag in the tags file to `target_image` with a local container tool, pulling `source_image` first when it is not local. `push` pushes `target_image:<tag>` for every tag. Both handle one platform; see [Multi-Platform Images](#multi-platform-images).

| Parameter | Default | Description |
| --- | --- | --- |
| `target_image` | *required* | Repository to tag and push, without a tag, e.g. `ghcr.io/org/app`. |
| `tags_file` | `tags.txt` | File with the tags, one per line, as written by `generate_tags`. |
| `tool` | `docker` | `docker`, `podman`, or `buildah`. |
| `source_image` (`tag` only) | *required* | Local or pullable image to tag. |
| `append_tags_to_source` (`tag` only) | `false` | Use `source_image:<tag>` as the source of each tag, instead of `source_image`. |
| `push` (`tag` only) | `false` | Push each tag after tagging, as `push` does. |

### `tag_digest`

Applies every tag in the tags file to an image that is already in a registry, without pulling or pushing it. See [Multi-Platform Images](#multi-platform-images).

| Parameter | Default | Description |
| --- | --- | --- |
| `image_digest_ref` | *required* | Image digest reference, `repository@sha256:<64 hex characters>`. |
| `tags_file` | `tags.txt` | File with the tags, one per line. |
| `expected_digests_file` | `""` | Optional file of `<tag> <sha256:digest>` or `<tag> absent` lines; any mismatch stops every write. |

### `export_tag`, `export_image_ref`, and `export_image_digest_ref`

These export a value to `BASH_ENV`, shell-quoted, so later steps in the same job can read it. Each `*_env_var` parameter is the *name* of an environment variable, not a value.

| Command | Parameter | Default | Description |
| --- | --- | --- | --- |
| `export_tag` | `tag_env_var` | `TAG` | Output: variable to write the most specific tag to (`1.2.3`, `main-<sha>`, or `dev-<sha>`). |
| `export_tag` | `git_tag_prefix`, `git_tag` | `""` | Same as in `generate_tags`. |
| `export_image_ref` | `image` | *required* | Repository without a tag, e.g. `ghcr.io/org/app`. |
| `export_image_ref` | `tag_env_var` | `TAG` | Input: variable that already holds the tag, as written by `export_tag`. |
| `export_image_ref` | `image_ref_env_var` | `IMAGE_REF` | Output: variable to write the image reference `<image>:<tag>` to. |
| `export_image_digest_ref` | `image_ref_env_var` | `IMAGE_REF` | Input: variable that already holds the image reference, as written by `export_image_ref`. |
| `export_image_digest_ref` | `image_digest_ref_env_var` | `IMAGE_DIGEST_REF` | Output: variable to write the image digest reference `<repository>@<digest>` to. |

`export_image_digest_ref` reads the digest with `crane digest` when crane is on `PATH`, and otherwise from docker's `RepoDigests`, pulling the image if it is not local. The image must already be in the registry. The step fails if no digest can be read.

```yaml
- tagger/export_tag                # TAG=1.2.3
- tagger/export_image_ref:
    image: ghcr.io/org/app         # IMAGE_REF=ghcr.io/org/app:1.2.3
# ...build and push ${IMAGE_REF}...
- tagger/export_image_digest_ref   # IMAGE_DIGEST_REF=ghcr.io/org/app@sha256:...
```

## Example Usage

The following example shows how to build a container image and then push it to a registry using this orb's automatic tag generation feature.

```yaml
usage:
  version: 2.1

  orbs:
    tagger: juburr/container-tagger-orb@0.8.0

  parameters:
    docker_version:
      type: string
      default: "default"

  jobs:
    container_build:
      docker:
        - image: cimg/base:current-22.04
      steps:
        - checkout
        - setup_remote_docker:
            version: << pipeline.parameters.docker_version >>
            docker_layer_caching: true
        - run:
            name: Build Docker Container
            command: |
              # Customize based on the needs of your project
              # In practice you will likely have many more build arguments, OCI labels, etc.
              docker build \
                --build-arg CREATED_ON=$(date -u +'%Y-%m-%dT%H:%M:%SZ') \
                --build-arg GITHUB_TOKEN=$GITHUB_TOKEN \
                --label org.opencontainers.image.source="https://github.com/org/repo" \
                -t localimage \
                -f containers/prod/localimage/Dockerfile \
                .
        - tagger/generate_tags:
            tags_file: tags.txt
        - tagger/tag:
            source_image: localimage
            target_image: ghcr.io/org/repo/image
            tags_file: tags.txt
        - run:
            name: Authenticate with GHCR
            command: echo $GITHUB_TOKEN | docker login ghcr.io -u $GITHUB_USER --password-stdin
        - tagger/push:
            target_image: ghcr.io/org/repo/image
            tags_file: tags.txt
        - run:
            name: Logout from GHCR
            command: docker logout ghcr.io

  workflows:
    on-tag:
      jobs:
        - container_build:
            context:
              - yourproject-github-pkg-rw
            filters:
              branches:
                ignore: /.*/
              tags:
                only: /^v(?!0\d)[0-9]+(\.(?!0\d)[0-9]+){2}(\-(alpha|beta|rc)([0-9]+|\.[0-9]+)?)?$/
```

## Multi-Platform Images

The `tag` and `push` commands work through a local container tool (`docker`, `podman`, or `buildah`), which holds one platform of an image. Pulling a multi-platform image, tagging it, and pushing it again replaces its index with a single-platform manifest.

For an image that is already in a registry, use `tag_digest`. It applies every tag in the tags file to `repository@sha256:<digest>` in place, with `crane tag`, and never pulls or pushes image content. Every tag ends up on the same index digest, with every platform.

```yaml
- run:
    name: Authenticate with GHCR
    command: echo $GITHUB_TOKEN | docker login ghcr.io -u $GITHUB_USER --password-stdin
- tagger/generate_tags:
    tags_file: tags.txt
- tagger/tag_digest:
    # The index digest your build pushed, for example from docker buildx --metadata-file.
    image_digest_ref: ghcr.io/org/repo/image@${BUILD_DIGEST}
    tags_file: tags.txt
```

How it behaves:
- `crane` must be on `PATH`; this orb does not install it. Registry credentials come from the Docker config, so `docker login` (or `crane auth login`) works.
- `image_digest_ref` must be `repository@sha256:<64 hex characters>`, and the tags are written to that same repository. `export_image_digest_ref` can produce it as `${IMAGE_DIGEST_REF}`. To promote into another repository, copy by digest first, for example `crane copy src@sha256:... dst@sha256:...`.
- Before writing, each tag's current digest is logged as `<tag> <sha256:...>` or `<tag> absent`.
- `expected_digests_file` takes that same format, one line per tag in the tags file. If any tag no longer matches, no tag is written. Use it to make sure the tags you planned to move have not moved since. The check runs just before writing and is not atomic; registries have no conditional tag write.
- A tag that already points at the digest is not rewritten.
- After writing, every tag must resolve to the source digest, or the step fails.
- If a write fails partway, the log lists the tags that were already written, and their previous digests are logged above it.

## Upgrading

Releases after 0.7.4 rename these commands and parameters. `source_tag` and `tag_digest` were added after 0.7.4, so their old names only matter if you tested a development version.

| Old | New |
| --- | --- |
| `populate_tag` | `export_tag` |
| `populate_image_uri` | `export_image_ref` |
| `populate_image_uri_digest` | `export_image_digest_ref` |
| `generate_tags.outfile` | `tags_file` |
| `package` (`generate_tags`, `populate_tag`) | `git_tag_prefix` |
| `source_tag` (`generate_tags`, `populate_tag`) | `git_tag` |
| `image_uri_env_var` (default `IMAGE_URI`) | `image_ref_env_var` (default `IMAGE_REF`) |
| `image_digest_env_var` (default `IMAGE_URI_DIGEST`) | `image_digest_ref_env_var` (default `IMAGE_DIGEST_REF`) |
| `tag_digest.image_digest` | `image_digest_ref` |

Behavior changes:
- The default exported variables are now `IMAGE_REF` and `IMAGE_DIGEST_REF`. Steps that read `${IMAGE_URI}` or `${IMAGE_URI_DIGEST}` must use the new names, or set `image_ref_env_var: IMAGE_URI` and `image_digest_ref_env_var: IMAGE_URI_DIGEST`.
- A leading `~/` in `tags_file` and `expected_digests_file` now means `$HOME`. It used to be taken literally, as a path under a directory named `~` in the working directory.
- `export_tag` and `export_image_ref` write shell-quoted values to `BASH_ENV`, as `export_image_digest_ref` already did.

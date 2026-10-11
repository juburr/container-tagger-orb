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

`alpha` and `beta` accept the same suffix shapes as `rc`. A tag pipeline whose git tag is not one of these forms fails, instead of publishing that release as `dev-<sha>` or `edge`.

This orb functions by reading your project's local `git tag` list to determine which versions already exist. If that list cannot be read, a final release fails instead of treating the tag being built as the newest version. An empty list is a first release and still publishes the floating tags.

Any merge into `master`, `main`, or `develop` will result in an `:edge` tag being created, provided your container build job is within a workflow that builds on non-tagged commits.

Running a Golang monorepo where you're creating tags such as `microservices/authservice/v1.0.5`? No problem. This is supported as well. Currently, you need to supply a `package: microservices/authservice` argument, but this could potentially be determined automatically in a future release.

## Example Usage

The following example shows how to build a container image and then push it to a registry using this orb's automatic tag generation feature.

```yaml
usage:
  version: 2.1

  orbs:
    tagger: juburr/container-tagger-orb@0.7.4

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
            outfile: tags.txt
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
    outfile: tags.txt
- tagger/tag_digest:
    # The index digest your build pushed, for example from docker buildx --metadata-file.
    image_digest: ghcr.io/org/repo/image@${BUILD_DIGEST}
    tags_file: tags.txt
```

How it behaves:
- `crane` must be on `PATH`; this orb does not install it. Registry credentials come from the Docker config, so `docker login` (or `crane auth login`) works.
- `image_digest` must be `repository@sha256:<64 hex characters>`, and the tags are written to that same repository. To promote into another repository, copy by digest first, for example `crane copy src@sha256:... dst@sha256:...`.
- Before writing, each tag's current digest is logged as `<tag> <sha256:...>` or `<tag> absent`.
- `expected_digests_file` takes that same format, one line per tag in the tags file. If any tag no longer matches, no tag is written. Use it to make sure the tags you planned to move have not moved since. The check runs just before writing and is not atomic; registries have no conditional tag write.
- A tag that already points at the digest is not rewritten.
- After writing, every tag must resolve to the source digest, or the step fails.
- If a write fails partway, the log lists the tags that were already written, and their previous digests are logged above it.

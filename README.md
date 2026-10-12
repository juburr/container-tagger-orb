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

`alpha` and `beta` accept the same suffix shapes as `rc`. A tag pipeline whose git tag is not one of these forms fails, instead of publishing that release as `dev-<sha>` or `edge`. The same forms apply to the `source_tag` parameter described below.

This orb functions by reading your project's local `git tag` list to determine which versions already exist. If that list cannot be read, a final release fails instead of treating the tag being built as the newest version. An empty list is a first release and still publishes the floating tags.

Any merge into `master`, `main`, or `develop` will result in an `:edge` tag being created, provided your container build job is within a workflow that builds on non-tagged commits.

Running a Golang monorepo where you're creating tags such as `microservices/authservice/v1.0.5`? No problem. This is supported as well. Currently, you need to supply a `package: microservices/authservice` argument, but this could potentially be determined automatically in a future release.

Only tags in the same namespace are compared when choosing `:latest`, `:X`, and `:X.Y`. With `package: microservices/authservice`, that is exactly `microservices/authservice/vX.Y.Z`; tags such as `microservices/authservice-legacy/v9.0.0` or `microservices/authservice/beta/v9.0.0` are ignored. Without a package, it is `vX.Y.Z` with no slash, so tags such as `zeta/v9.9.9`, `wip-v5.0.0`, or `opengee-v5.3.9` are ignored.

### Releasing without a tag pipeline: `source_tag`

By default the release identity is `CIRCLE_TAG`, and when that is empty, `CIRCLE_BRANCH` selects `:edge` or a `dev-<sha>` tag. Some release workflows do not run from a tag pipeline, for example a protected `release-execution/<tag>` branch that carries its own validated release tag. Pass that tag to both `generate_tags` and `populate_tag` as `source_tag`:

```yaml
- tagger/populate_tag:
    source_tag: ${RELEASE_TAG}
- tagger/generate_tags:
    source_tag: ${RELEASE_TAG}
```

When `source_tag` is set:
- It is the only release identity. `CIRCLE_BRANCH` is not consulted, so a release whose pipeline runs on `main` does not also publish `:edge` or `main-<sha>`.
- It must be a supported release tag, using the same forms listed above. Anything else fails the step. There is no fallback to `CIRCLE_TAG`, `:edge`, `main-<sha>`, or `dev-<sha>`.
- If `CIRCLE_TAG` is also set, the two must be identical.
- With a `package`, it must be the full tag name, `<package>/vX.Y.Z`. A bare `vX.Y.Z` or another package's prefix fails, because those are different git tags. (`CIRCLE_TAG` still also accepts a bare `vX.Y.Z` with a package, for compatibility.)
- A value that expands to an empty string, such as `${RELEASE_TAG}` when that variable is unset, fails the step instead of falling back. To keep the default behaviour, leave the parameter empty, for example with a pipeline parameter that defaults to `""`.
- A final release still reads the local `git tag` list to choose `:latest`, `:X`, and `:X.Y`. A branch checkout might not contain every release tag; fetch them first if needed, for example with `git fetch --tags origin`.

Both commands log which identity they used: `source_tag`, `CIRCLE_TAG`, or the branch.

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

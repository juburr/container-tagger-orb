<div align="center">
  <img align="center" width="320" src="assets/logos/container-tagger-orb-v3.png" alt="Container Tagger Orb">
  <h1>CircleCI Container Tagger Orb</h1>
  <i>An orb for automatically tagging container images within CircleCI.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/container-tagger-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/container-tagger-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/container-tagger-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/container-tagger-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/container-tagger-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

This is an orb for automatically tagging container images within your CircleCI pipeline using semantic versioning, allowing you to release multiple tags simultaneously.

<div align="center">
    <img align="center" width="500" src="assets/tagger-concept-v2.png" alt="Container Tagger Concept">
</div>

### Motivation
For new versions of your software, it's often desirable to release multiple tags for a given image. For example, instead of just releasing `:2.5.2` as a single tag for your new image, you may also want to tag a whole series of images:
- `:latest` - the latest and greatest version of your software
- `:2.5.2` - the actual version number
- `:2.5` - latest patch in the 2.5 series
- `:2` - latest release in the 2 series

We don't want to apply these tags with every release though. Suppose you later release an emergency security patch to the 2.4 series of your software. In that case, you don't want to tag that image to receive the `:latest` tag.. or even the `:2` tag for the matter. The new image should only receive two tags:
- `:2.1.8`
- `:2.1`

Some projects may also want to maintain an `:edge` tag containing the very latest succesful merges into trunk that have yet to receive an official tag, thereby allowing you to easily pull down images prior to the next release going out.

This orb will take care of these edge cases and more.

### Assumptions and Strategy

This orb requires that your git tags are semantically versioned. Examples of valid tags include:
- `v2.5.2`
- `v2.5.3-rc1`
- `v2.5.3-alpha1`
- `v2.5.3-beta4`

This orb functions by pulling down your project's `git tag` list to determine which versions already exist.

Any merge into `master`, `main`, or `develop` will result in an `:edge` tag being created, assuming your container build job is within a workflow that builds on non-tags.

Running a Golang monorepo where you're creating tags such as `microservices/authservice/v1.0.5`? No problem. This is supported as well. For now you need to support a `package: microservices/authservice` argument, but this could very well be determined automatically in a future release.

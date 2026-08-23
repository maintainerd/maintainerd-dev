# Shared build for any maintainerd Go service. The build context is the parent
# dir (all sibling modules + go.work), so the suite's local modules resolve via
# the workspace without published modules. Pass SERVICE (module dir) and CMD_PATH.
FROM golang:1.26 AS build
# Let Go fetch the exact toolchain the modules pin (go.work/go.mod may require a
# newer patch than the base image ships).
ENV GOTOOLCHAIN=auto
WORKDIR /src
COPY . .
ARG SERVICE
ARG CMD_PATH
# CACHE MOUNTS, for the same reason the console images have them: the dev stack
# builds three Go services and four SPAs concurrently, so a laptop's link is
# saturated and a module fetch can time out. Without a cache, every retry
# re-downloads the entire module graph — including the AWS, GCP, Azure and Vault
# SDKs the kit's secret providers pull in — so a transient failure costs the whole
# download again.
#
# sharing=locked rather than the default: three services build at once against one
# module cache, and concurrent writers to the same Go cache corrupt it.
#
# Deliberately NOT split into a separate `go mod download` layer: the build context
# is a Go WORKSPACE (go.work over sibling modules), where `go mod download` in one
# module directory does not reliably resolve the workspace's replace graph. One
# step that is correct beats two that are faster and fragile.
RUN --mount=type=cache,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,target=/root/.cache/go-build,sharing=locked \
    cd "${SERVICE}" && CGO_ENABLED=0 go build -o /out/app "./${CMD_PATH}"

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
ENTRYPOINT ["/app"]

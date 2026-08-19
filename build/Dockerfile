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
RUN cd "${SERVICE}" && CGO_ENABLED=0 go build -o /out/app "./${CMD_PATH}"

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
ENTRYPOINT ["/app"]

# ape-sandbox image — build & publish.
#
# Builds the PUBLIC, framework-free ape-sandbox workspace image and publishes it
# to the public ghcr.io/exoport/ape-sandbox package. There is no build secret and
# nothing private in the image: the APEX framework is mounted read-only at runtime
# by aped, so any node or laptop can pull this with no credential.
#
# Quick start (local build straight into a running aped's containerd namespace, so
# `ape sandbox up` finds it with no registry round-trip):
#   make build NERDCTL="sudo nerdctl" NAMESPACE=aped
#
# Publish:
#   make login       # or: echo $PAT | nerdctl login ghcr.io -u <user> --password-stdin
#   make publish

IMAGE_REPO  ?= ghcr.io/exoport/ape-sandbox
# The image's OWN version, independent of ape (see the Dockerfile's VERSIONING note):
# it changes for base/asdf/bingo/Playwright reasons that have nothing to do with ape.
VERSION     ?= v1.0.0
TAG         ?= $(VERSION)
# Which ape release is baked in — a dependency pin, bumped deliberately. Floor: v0.0.49
# (`ape framework setup` needs the scoped safe.directory fix for the read-only mount).
APE_VERSION ?= v0.0.49
IMAGE       := $(IMAGE_REPO):$(TAG)

# Container CLI. Local builds on the aped host need the rootful daemon, so
# override with: make build NERDCTL="sudo nerdctl"
NERDCTL ?= nerdctl
# Containerd namespace. Use NAMESPACE=aped to build into a local aped's namespace.
NAMESPACE ?=
NS_FLAG := $(if $(NAMESPACE),--namespace $(NAMESPACE),)

BUILD_ARGS := --build-arg APE_VERSION=$(APE_VERSION)

.PHONY: help
help: ## Show targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  IMAGE=$(IMAGE)  (public, framework-free)  bakes ape $(APE_VERSION)"

.PHONY: build
build: ## Build the image. Set NAMESPACE=aped for local aped use.
	$(NERDCTL) $(NS_FLAG) build $(BUILD_ARGS) -t $(IMAGE) .

.PHONY: smoke
smoke: ## Verify the built image carries the expected tooling
	$(NERDCTL) $(NS_FLAG) run --rm $(IMAGE) sh -lc '\
	  set -e; \
	  ape version; \
	  claude --version; \
	  asdf --version; \
	  bingo version; \
	  git --version; \
	  test -d /opt/apex-framework && echo "framework mountpoint present (empty by design)"; \
	  test -d /workspace && test -d /cache && echo "workspace + cache mountpoints present"'

.PHONY: login
login: ## Log in to ghcr.io
	$(NERDCTL) login ghcr.io

.PHONY: push
push: ## Push the built image
	$(NERDCTL) $(NS_FLAG) push $(IMAGE)

.PHONY: publish
publish: build push ## Build then push

.PHONY: print-vars
print-vars: ## Print resolved variables
	@echo "IMAGE=$(IMAGE)"
	@echo "NERDCTL=$(NERDCTL)  NAMESPACE=$(NAMESPACE)"

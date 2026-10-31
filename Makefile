# Variables
APP_NAME    ?= server
IMAGE_NAME  ?= myorg/$(APP_NAME)
PORT        ?= 8080

# Git metadata for versioning
GIT_COMMIT  := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_TAG     := $(shell git describe --tags --exact-match 2>/dev/null || echo "")
APP_VERSION ?= $(if $(GIT_TAG),$(GIT_TAG),$(GIT_COMMIT))

# Multi-platform support
PLATFORMS   ?= linux/amd64,linux/arm64

.PHONY: help build run stop test tidy clean buildx-init buildx-push

# Default target
help: ## Display this help screen
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

## --- Local Go Tooling ---

tidy: ## Download and verify dependencies
	go mod tidy
	go mod verify

test: ## Run unit tests locally
	CGO_ENABLED=0 go test -v -race ./...

## --- Docker Targets ---

build: ## Build Docker image for the current host architecture
	docker build \
		--build-arg APP_VERSION=$(APP_VERSION) \
		-t $(IMAGE_NAME):latest \
		-t $(IMAGE_NAME):$(APP_VERSION) .

run: ## Run container locally in background
	docker run -d \
		--name $(APP_NAME) \
		-p $(PORT):8080 \
		--rm \
		$(IMAGE_NAME):latest
	@echo "Container running at http://localhost:$(PORT)"

stop: ## Stop the running container
	-docker stop $(APP_NAME)

logs: ## Follow container logs
	docker logs -f $(APP_NAME)

## --- Multi-Arch / CI Builds ---

buildx-init: ## Set up Docker buildx builder instance
	@docker buildx inspect multi-builder > /dev/null 2>&1 || \
		docker buildx create --name multi-builder --driver docker-container --use
	docker buildx inspect --bootstrap

buildx-push: buildx-init ## Build and push multi-arch image (amd64, arm64) to registry
	docker buildx build \
		--platform $(PLATFORMS) \
		--build-arg APP_VERSION=$(APP_VERSION) \
		-t $(IMAGE_NAME):latest \
		-t $(IMAGE_NAME):$(APP_VERSION) \
		--push .

## --- Cleanup ---

clean: stop ## Remove generated Docker images and prune builder cache
	-docker rmi $(IMAGE_NAME):latest $(IMAGE_NAME):$(APP_VERSION)
	docker builder prune -f
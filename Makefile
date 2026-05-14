# =============================================================================
# Dream Studio Upscaler — build & deploy helpers
#
#   make help          show this list
#   make build         build :latest + :YYYYMMDD images
#   make push          push both tags to the registry
#   make deploy        apply ConfigMap (frontend/) + Deployment + Service
#   make ui-reload     re-project frontend/ into the sidecar (no rebuild)
#   make rollout       restart the deployment (picks up a new :latest image)
#   make logs          tail forgeui container logs
#   make logs-save     dump 24h of forgeui + nginx logs to ./logs/<stamp>.log
#   make shell         exec into the running Forge container
#   make status        describe the pod (events, probes, GPU)
# =============================================================================

REGISTRY     ?= aylopop
IMAGE_NAME   ?= dream-studio-upscaler
NAMESPACE    ?= default
DEPLOY       ?= dream-studio-upscaler

DATE_TAG := $(shell date +%Y%m%d)
IMAGE    := $(REGISTRY)/$(IMAGE_NAME)
IMAGE_UI := $(REGISTRY)/$(IMAGE_NAME)-ui

.PHONY: help build build-ui build-all push push-ui push-all deploy apply-ui-config ui-reload rollout logs logs-attention logs-save shell status

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //'

## build      build :latest + :<date> Forge backend image from local forks
build:
	docker build -t $(IMAGE):latest -t $(IMAGE):$(DATE_TAG) .

## build-ui   build :latest + :<date> nginx UI image (frontend/ baked in)
build-ui:
	docker build -f Dockerfile.ui -t $(IMAGE_UI):latest -t $(IMAGE_UI):$(DATE_TAG) .

## build-all  build both backend and UI images
build-all: build build-ui

## push       push backend tags to the registry
push:
	docker push $(IMAGE):latest
	docker push $(IMAGE):$(DATE_TAG)

## push-ui    push UI tags to the registry
push-ui:
	docker push $(IMAGE_UI):latest
	docker push $(IMAGE_UI):$(DATE_TAG)

## push-all   push both backend and UI tags
push-all: push push-ui

## deploy     apply Deployment + Service, then load the UI ConfigMap and roll
deploy:
	kubectl -n $(NAMESPACE) apply -f deployment.yaml
	$(MAKE) apply-ui-config
	kubectl -n $(NAMESPACE) rollout restart deploy/$(DEPLOY)
	kubectl -n $(NAMESPACE) rollout status deploy/$(DEPLOY)

## apply-ui-config  rebuild the ConfigMap from frontend/{index.html,nginx.conf,config.json,logo.png}
##
## --server-side: classic `kubectl apply` stores the full resource in a
## last-applied-configuration ANNOTATION, capped at 256KB. With logo.png
## (~166KB, ~221KB base64-encoded) + the rest of the bundle, we overflow.
## Server-side apply tracks the desired state on the API server itself
## with no client-side annotation, so the size limit doesn't apply.
## --force-conflicts so we own all fields (single writer).
apply-ui-config:
	kubectl -n $(NAMESPACE) create configmap upscaler-ui-files \
		--from-file=index.html=frontend/index.html \
		--from-file=nginx.conf=frontend/nginx.conf \
		--from-file=config.json=frontend/config.json \
		--from-file=logo.png=frontend/logo.png \
		--from-file=logo-icon.svg=frontend/logo-icon.svg \
		--from-file=save-sidecar.py=frontend/save-sidecar.py \
		--dry-run=client -o yaml | kubectl -n $(NAMESPACE) apply --server-side --force-conflicts -f -

## ui-reload  re-apply the ConfigMap and restart the sidecar (no image build)
ui-reload: apply-ui-config
	kubectl -n $(NAMESPACE) rollout restart deploy/$(DEPLOY)
	kubectl -n $(NAMESPACE) rollout status deploy/$(DEPLOY)

## rollout    restart the deployment to pick up a new :latest image
rollout:
	kubectl -n $(NAMESPACE) rollout restart deploy/$(DEPLOY)
	kubectl -n $(NAMESPACE) rollout status deploy/$(DEPLOY)

## logs       follow Forge container logs
logs:
	kubectl -n $(NAMESPACE) logs -f deploy/$(DEPLOY) -c forgeui

## logs-attention  show which attention backend Forge picked at startup
##                 ("Using SageAttention 2 ..." = sage worked;
##                  "Using PyTorch Cross Attention" = fell back to slow path)
logs-attention:
	@kubectl -n $(NAMESPACE) logs deploy/$(DEPLOY) -c forgeui \
	  | grep -iE "Using.*Attention|sage|xformers|flash_attn" | head -20 \
	  || echo "(no attention lines yet — pod still starting?)"

## logs-save  dump last 24h of forgeui + nginx logs to ./logs/<timestamp>.log
logs-save:
	@mkdir -p logs
	@stamp=$$(date +%Y%m%d-%H%M%S); \
	out=logs/dream-studio-upscaler-$$stamp.log; \
	{ \
	  echo "=== forgeui (last 24h) ==="; \
	  kubectl -n $(NAMESPACE) logs --since=24h deploy/$(DEPLOY) -c forgeui; \
	  echo; echo "=== upscaler-ui (last 24h) ==="; \
	  kubectl -n $(NAMESPACE) logs --since=24h deploy/$(DEPLOY) -c upscaler-ui; \
	} > $$out 2>&1; \
	echo "wrote $$out ($$(wc -l < $$out) lines)"

## shell      open a shell in the Forge container
shell:
	kubectl -n $(NAMESPACE) exec -it deploy/$(DEPLOY) -c forgeui -- bash

## status     describe the pod (events, probes, GPU)
status:
	kubectl -n $(NAMESPACE) describe pod -l app=$(DEPLOY)

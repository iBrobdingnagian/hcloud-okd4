.DEFAULT_GOAL := build

# ocp
OPENSHIFT_MIRROR?=https://mirror.openshift.com/pub/openshift-v4
OCP_RELEASE_CHANNEL?=stable-4.19

# okd
OKD_MIRROR?=https://github.com/okd-project/okd/releases/download

# either okd or ocp
DEPLOYMENT_TYPE?=okd

# fixed release version
OPENSHIFT_RELEASE?=none

# image name
CONTAINER_NAME?=quay.io/slauger/hcloud-okd4
CONTAINER_TAG?=$(OPENSHIFT_RELEASE)

# coreos
ifeq ($(DEPLOYMENT_TYPE),ocp)
	COREOS_IMAGE=rhcos
else ifeq ($(DEPLOYMENT_TYPE),okd)
	COREOS_IMAGE=fcos
else
	$(error installer only supports ocp or okd)
endif

# terraform switches
BOOTSTRAP?=false
MODE?=apply

# packer build server (overridden via .env)
PACKER_LOCATION?=nbg1
PACKER_SERVER_TYPE?=cx33
# snapshot label so deploys can find/reuse the image for this CoreOS release
TF_VAR_fcos_release?=

# openshift version
.PHONY: latest_version
latest_version: latest_version_$(DEPLOYMENT_TYPE)

.PHONY: latest_version_okd
latest_version_okd:
	@curl -s -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/okd-project/okd/tags | jq -j -r .[0].name

.PHONY: latest_version_ocp
latest_version_ocp:
	@curl -s https://raw.githubusercontent.com/openshift/cincinnati-graph-data/master/channels/$(OCP_RELEASE_CHANNEL).yaml | egrep '(4\.[0-9]+\.[0-9]+)' | tail -n1 | cut -d" " -f2

# fetch
.PHONY: fetch
fetch: fetch_$(DEPLOYMENT_TYPE)

.PHONY: fetch_okd
fetch_okd:
	wget -O openshift-install-linux-$(OPENSHIFT_RELEASE).tar.gz $(OKD_MIRROR)/$(OPENSHIFT_RELEASE)/openshift-install-linux-$(OPENSHIFT_RELEASE).tar.gz
	wget -O openshift-client-linux-$(OPENSHIFT_RELEASE).tar.gz $(OKD_MIRROR)/$(OPENSHIFT_RELEASE)/openshift-client-linux-$(OPENSHIFT_RELEASE).tar.gz

.PHONY: fetch_ocp
fetch_ocp:
	wget -O openshift-install-linux-$(OPENSHIFT_RELEASE).tar.gz $(OPENSHIFT_MIRROR)/clients/ocp/$(OPENSHIFT_RELEASE)/openshift-install-linux-$(OPENSHIFT_RELEASE).tar.gz
	wget -O openshift-client-linux-$(OPENSHIFT_RELEASE).tar.gz $(OPENSHIFT_MIRROR)/clients/ocp/$(OPENSHIFT_RELEASE)/openshift-client-linux-$(OPENSHIFT_RELEASE).tar.gz

.PHONY: build
build:
	docker build --build-arg DEPLOYMENT_TYPE=$(DEPLOYMENT_TYPE) --build-arg OPENSHIFT_RELEASE=$(OPENSHIFT_RELEASE) -t $(CONTAINER_NAME):$(CONTAINER_TAG) .

.PHONY: test
test:
	docker run -v /var/run/docker.sock:/var/run/docker.sock -v $(shell pwd):/src:ro gcr.io/gcp-runtimes/container-structure-test:latest test --image $(CONTAINER_NAME):$(CONTAINER_TAG) --config /src/tests/image.tests.yaml

.PHONY: push
push:
	docker push $(CONTAINER_NAME):$(CONTAINER_TAG)

.PHONY: run
run:
	docker run -it --hostname openshift-toolbox --mount type=bind,source="$(shell pwd)",target=/workspace --mount type=bind,source="$(HOME)/.ssh,target=/root/.ssh" $(CONTAINER_NAME):$(CONTAINER_TAG) /bin/bash

.PHONY: generate_manifests
generate_manifests:
	mkdir config
	cp install-config.yaml config/install-config.yaml
	openshift-install create manifests --dir=config

.PHONY: generate_ignition
generate_ignition:
	rsync -av config/ ignition
	openshift-install create ignition-configs --dir=ignition

.PHONY: hcloud_image
hcloud_image:
	@if [ -z "$(HCLOUD_TOKEN)" ]; then echo "ERROR: HCLOUD_TOKEN is not set"; exit 1; fi
	if [ "$(DEPLOYMENT_TYPE)" == "okd" ]; then (cd packer && packer build -var location=$(PACKER_LOCATION) -var server_type=$(PACKER_SERVER_TYPE) -var fcos_release=$(TF_VAR_fcos_release) -var fcos_url=$(shell openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.qemu.formats | (."qcow2.gz" // ."qcow2.xz").disk.location') hcloud-fcos.json); fi
	if [ "$(DEPLOYMENT_TYPE)" == "ocp" ]; then (cd packer && packer build -var location=$(PACKER_LOCATION) -var server_type=$(PACKER_SERVER_TYPE) -var rhcos_url=$(shell openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.qemu.formats."qcow2.gz".disk.location') hcloud-rhcos.json); fi

.PHONY: sign_csr
sign_csr:
	@if [ ! -f "ignition/auth/kubeconfig" ]; then echo "ERROR: ignition/auth/kubeconfig not found"; exit 1; fi
	bash -c "export KUBECONFIG=$(shell pwd)/ignition/auth/kubeconfig; oc get csr -o name | xargs oc adm certificate approve || true"

.PHONY: wait_bootstrap
wait_bootstrap:
	openshift-install --dir=ignition/ wait-for bootstrap-complete --log-level=debug

.PHONY: wait_completion
wait_completion:
	openshift-install --dir=ignition/ wait-for install-complete --log-level=debug

.PHONY: infrastructure
# NOTE: `apply` runs in two phases — create the servers first, then everything
# else — so the node IPs that hcloud_firewall rules reference (source_ips) are
# KNOWN when the firewall is planned. This avoids the hcloud provider bug
# "Provider produced inconsistent final plan ... does not correlate" that hits the
# etcd/east-west rules when a server is (re)created in the same apply. destroy/plan
# stay single-phase.
#
# Phase 2 is wrapped in a retry: the hcloud provider intermittently fails the
# LB/network/rdns resources with transient races ("WaitForAction: resource not
# found", "inconsistent result after apply: Root object ... now absent"). These
# converge on a re-apply, so retry up to 3x before giving up rather than aborting
# the whole deploy. (Never run two applies concurrently — they corrupt the shared
# state; these retries are strictly sequential.)
infrastructure:
	@if [ -z "$(TF_VAR_dns_domain)" ]; then echo "ERROR: TF_VAR_dns_domain is not set"; exit 1; fi
	@if [ -z "$(TF_VAR_dns_zone_id)" ]; then echo "ERROR: TF_VAR_dns_zone_id is not set"; exit 1; fi
	@if [ -z "$(HCLOUD_TOKEN)" ]; then echo "ERROR: HCLOUD_TOKEN is not set"; exit 1; fi
	@if [ -z "$(CLOUDFLARE_EMAIL)" ]; then echo "ERROR: CLOUDFLARE_EMAIL is not set"; exit 1; fi
	(cd terraform && terraform init && \
	 case "$(MODE)" in \
	   apply*) \
	     echo "==> two-phase apply [1/2]: servers first (so firewall source_ips resolve)" && \
	     terraform $(MODE) -target=module.bootstrap -target=module.master -target=module.worker -var image=$(COREOS_IMAGE) -var bootstrap=$(BOOTSTRAP) && \
	     echo "==> two-phase apply [2/2]: full apply (firewall / LB / DNS)" && \
	     { n=1; until terraform $(MODE) -var image=$(COREOS_IMAGE) -var bootstrap=$(BOOTSTRAP); do \
	         if [ $$n -ge 3 ]; then echo "==> phase 2 still failing after $$n attempts — giving up"; exit 1; fi; \
	         n=$$((n+1)); echo "==> phase 2 hit a transient hcloud error — retry $$n/3 in 15s"; sleep 15; \
	       done; } ;; \
	   *) terraform $(MODE) -var image=$(COREOS_IMAGE) -var bootstrap=$(BOOTSTRAP) ;; \
	 esac)
	if [ "$(MODE)" == "apply" ]; then (cd ansible && ansible-playbook site.yml); fi

.PHONY: destroy
destroy:
	(cd terraform && terraform init && terraform destroy)

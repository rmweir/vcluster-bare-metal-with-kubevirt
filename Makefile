.PHONY: vind-up vind-down vind-resume refresh-capacity fix-multus-memory vind-status vind-persist install install-cert-manager install-cni-static install-kubevirt install-bridge install-platform reset-admin-password install-os-image install-ssh-key install-node-provider install-network-environment create-vms create-machine create-vcluster create-vcluster-template create-ssh-service

CLUSTER_NAME ?= bare-metal-fun
KUBECONFIG := $(CURDIR)/kubeconfig
export KUBECONFIG

PLATFORM_VERSION ?= 4.12.0
CERT_MANAGER_VERSION ?= v1.19.2
KUBEVIRT_VERSION ?= v1.7.1
CDI_VERSION ?= v1.64.0

vind-up:
	vcluster --driver docker create $(CLUSTER_NAME)
	vcluster --driver docker connect $(CLUSTER_NAME) --print > $(KUBECONFIG)

vind-down:
	vcluster --driver docker delete $(CLUSTER_NAME)
	rm -f $(KUBECONFIG)

# Bring the cluster back after a reboot or suspend. The container has no restart
# policy by default (see vind-persist), and on start some pods are left behind as
# Unknown/UnexpectedAdmissionError because the kubelet cannot reclaim them.
vind-resume:
	docker start vcluster.cp.$(CLUSTER_NAME)
	vcluster --driver docker connect $(CLUSTER_NAME) --print > $(KUBECONFIG)
	@echo "Waiting for the API server..."
	@for i in $$(seq 1 60); do kubectl get nodes >/dev/null 2>&1 && break; sleep 5; done
	@kubectl get nodes >/dev/null 2>&1 || { echo "ERROR: API server did not come up"; exit 1; }
	@echo "Waiting for the node to be Ready..."
	@for i in $$(seq 1 60); do \
		[ "$$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $$2}')" = "Ready" ] && break; sleep 5; done
	@echo "Force-deleting only pods that cannot self-heal..."
	@kubectl get pods -A --no-headers 2>/dev/null \
		| awk '$$4=="UnexpectedAdmissionError" || $$4=="NodeAffinity" {print $$1" "$$2}' \
		| while read ns pod; do \
			kubectl delete pod "$$pod" -n "$$ns" --force --grace-period=0 >/dev/null 2>&1 \
				&& echo "  deleted $$ns/$$pod"; \
		done
	@echo "Waiting for CNI (multus) to be Running..."
	@ok=0; for i in $$(seq 1 36); do \
		st=$$(kubectl get pods -A --no-headers 2>/dev/null | awk '/kube-multus/{print $$3" "$$4}'); \
		case "$$st" in *"1/1 Running"*) ok=1; break;; esac; \
		sleep 5; \
	done; \
	if [ $$ok -ne 1 ]; then \
		echo; echo "ERROR: multus is not Running - CNI is down, so nothing else will start."; \
		kubectl get pods -A 2>/dev/null | awk 'NR==1 || /kube-multus/'; \
		echo; echo "Most likely OOMKilled (default limit is only 50Mi). Check with:"; \
		echo "  kubectl get pod -n default -l app=multus -o jsonpath='{.items[0].status.containerStatuses[0].lastState}'"; \
		echo "Raise it with:"; \
		echo "  kubectl set resources ds kube-multus-ds -n default -c kube-multus --limits=memory=512Mi --requests=memory=64Mi"; \
		echo "See MULTUS-MEMORY note in manifests/node-provider.yaml."; \
		exit 1; \
	fi
	@echo "Waiting for cluster DNS..."
	@ok=0; for i in $$(seq 1 36); do \
		[ "$$(kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '/coredns/{print $$2}')" = "1/1" ] && { ok=1; break; }; \
		sleep 5; \
	done; \
	[ $$ok -eq 1 ] || { echo "ERROR: coredns never became ready - check CNI first."; exit 1; }
	@echo "Clearing crash-loop backoff left over from the cold start..."
	@kubectl get pods -A --no-headers 2>/dev/null \
		| awk '$$4=="CrashLoopBackOff" {print $$1" "$$2}' \
		| while read ns pod; do \
			kubectl delete pod "$$pod" -n "$$ns" --force --grace-period=0 >/dev/null 2>&1 \
				&& echo "  reset $$ns/$$pod"; sleep 3; \
		done
	@echo "Waiting for the platform..."
	@for i in $$(seq 1 60); do \
		[ "$$(kubectl get pods -n vcluster-platform --no-headers 2>/dev/null | awk '/^loft-/{print $$2}')" = "1/1" ] && break; sleep 10; done
	@echo
	@$(MAKE) --no-print-directory vind-status

# The bundled multus chart hardcodes a 50Mi memory limit, which gets OOMKilled by
# the CNI stampede on cluster restart. Without CNI, coredns never starts and the
# whole stack stays down. Not settable via the NodeProvider's multus helmValues.
fix-multus-memory:
	kubectl set resources ds kube-multus-ds -n default -c kube-multus \
		--limits=memory=512Mi --requests=memory=64Mi
	@kubectl rollout status ds/kube-multus-ds -n default --timeout=120s
	@echo "multus limit is now: $$(kubectl get ds kube-multus-ds -n default -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')"

vind-status:
	@echo "== platform =="; kubectl get pods -n vcluster-platform 2>&1 | head -6
	@echo "== platform endpoint =="; kubectl get svc -n vcluster-platform 2>&1 | grep -iE 'NAME|loadbalancer'
	@echo "== bare metal hosts =="; kubectl get baremetalhost -A 2>&1
	@echo "== node claims =="; kubectl get nodeclaim -A 2>&1
	@echo "== tenant clusters =="; kubectl get pods -A 2>&1 | grep -E 'loft-.*-v-|NAME' | head -5

# Opt in to the container restarting itself on boot. This only brings the
# container back; the in-cluster cleanup in vind-resume is still needed.
vind-persist:
	docker update --restart unless-stopped vcluster.cp.$(CLUSTER_NAME)
	@echo "$(CLUSTER_NAME) will now start automatically. Run 'make vind-resume' after boot."

install: install-cert-manager install-cni-static install-kubevirt install-bridge install-platform reset-admin-password install-os-image install-ssh-key install-node-provider install-network-environment

install-cert-manager:
	helm upgrade --install cert-manager cert-manager \
		--repo https://charts.jetstack.io \
		--namespace cert-manager \
		--create-namespace \
		--version $(CERT_MANAGER_VERSION) \
		--set crds.enabled=true \
		--wait

install-cni-static:
	kubectl apply -f manifests/cni-static-plugin.yaml
	kubectl rollout status daemonset/cni-static-plugin -n kube-system --timeout=120s

install-kubevirt:
	kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/$(KUBEVIRT_VERSION)/kubevirt-operator.yaml
	kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/$(KUBEVIRT_VERSION)/kubevirt-cr.yaml
	kubectl wait --for=condition=Available --timeout=300s -n kubevirt deployment/virt-operator
	kubectl apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/$(CDI_VERSION)/cdi-operator.yaml
	kubectl apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/$(CDI_VERSION)/cdi-cr.yaml
	kubectl wait --for=condition=Available --timeout=300s -n cdi deployment/cdi-operator

install-bridge:
	kubectl apply -f manifests/bridge-setup.yaml

install-platform:
	if [ -z "$$LICENSE_TOKEN" ]; then \
		read -p "Enter platform license token (leave empty to reuse existing): " LICENSE_TOKEN; \
	fi; \
	if [ -n "$$LICENSE_TOKEN" ]; then \
		LICENSE_FLAGS="--set env.LICENSE_TOKEN=$$LICENSE_TOKEN"; \
	else \
		LICENSE_FLAGS="--reuse-values"; \
	fi; \
	echo $$LICENSE_FLAGS; \
	helm upgrade --install vcluster-platform \
		--repo https://charts.loft.sh/ vcluster-platform \
		--version $(PLATFORM_VERSION) \
		--namespace vcluster-platform \
		--create-namespace \
		--values manifests/platform-values.yaml \
		$$LICENSE_FLAGS \
		--wait

reset-admin-password:
	vcluster platform reset password --user admin

create-vms:
	helm upgrade --install vm vm/ --namespace default

install-os-image:
	kubectl apply -f manifests/os-image.yaml

install-ssh-key:
	kubectl apply -f manifests/ssh-key.yaml

install-node-provider:
	kubectl apply -f manifests/node-provider.yaml

install-network-environment:
	kubectl apply -f manifests/node-environment.yaml

# Force the NodeType to recompute its capacity.
#
# The node-type-controller does not watch BareMetalHosts and only reconciles on
# a NodeType *generation* change. After a host is released (claim deleted),
# capacity stays stale, so new claims sit Pending with "no available and
# matching node type found for node claim requirements" even though a host is
# available.
#
# cost is the only field that both propagates to the NodeType and changes its
# generation, so we bump it and immediately set it back to 0. cost affects how
# likely a node type is to be selected and is shown in the UI, so we do not
# leave an arbitrary value behind.
#
# Symptom this fixes:
#   kubectl get nodetypes   -> claimed == total (no free capacity)
#   claim message           -> "no available and matching node type found"
refresh-capacity:
	@kubectl patch nodeprovider metal3 --type=merge \
		-p '{"spec":{"metal3":{"nodeTypes":[{"name":"vm","cost":1}]}}}' >/dev/null
	@sleep 15
	@kubectl patch nodeprovider metal3 --type=merge \
		-p '{"spec":{"metal3":{"nodeTypes":[{"name":"vm","cost":0}]}}}' >/dev/null
	@sleep 15
	@echo "capacity refreshed:"
	@kubectl get nodetypes

create-machine:
	kubectl apply -f manifests/node-claim.yaml

create-vcluster:
	kubectl apply -f manifests/vcluster.yaml

create-vcluster-template:
	kubectl apply -f manifests/vcluster-template.yaml

create-ssh-service:
	kubectl apply -f manifests/ssh-service.yaml

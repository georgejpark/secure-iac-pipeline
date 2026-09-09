# How these tools actually fit together

Terraform, Docker, Colima, Helm, Kubernetes, DaemonSets, autoscaling — where each one belongs, and
two common mix-ups worth avoiding out loud.

---

## Two corrections first

### 1. Colima is a laptop tool, not a server tool

Colima runs a small Linux VM on **macOS** so a Mac can run Docker without Docker Desktop. It exists
to solve "my laptop isn't Linux."

Your Proxmox containers **are already Linux**. Installing Colima there would nest a Linux VM inside a
Linux container inside a Linux hypervisor to reach a Linux kernel you already had.

| Where | To run containers, use |
|---|---|
| Your Mac | Colima, Rancher Desktop, or Docker Desktop |
| A Linux server | `docker` or `podman` — installed directly |
| A Linux server, orchestrated | **k3s** or full Kubernetes |

**"Unicon" is not a tool.** You may be thinking of **Lima** (what Colima is built on), **Podman**
(daemonless Docker alternative), or **unikernels** (a single-purpose machine image — unrelated). If
it comes up, say "Lima" or "Podman" — naming a tool that doesn't exist is worse than not naming one.

### 2. DaemonSets do not autoscale

This is the one that matters most.

| Primitive | Replica count is | Use it for |
|---|---|---|
| **Deployment** | whatever you set, scheduler places them | **web services — this is what you want** |
| **DaemonSet** | exactly one per node, always | log shippers, metrics agents, CNI, node exporters |
| **StatefulSet** | fixed, ordered, stable storage | databases, queues, brokers |

A DaemonSet's count is **tied to node count**. Scaling it means adding nodes. So "autoscaling
DaemonSet workers" is a contradiction — if you scale a DaemonSet you are scaling the cluster, not the
workload.

**What you want:** a `Deployment` for the app, plus a `HorizontalPodAutoscaler`.
**Where a DaemonSet genuinely fits:** the log shipper on every node, sending to your SIEM. That is a
real and good use — just not the application tier.

---

## The layers, bottom to top

```
Terraform      →  the cluster and the machines it runs on
Docker         →  build the app into an image
a registry     →  store the image, scan it
Helm           →  template the Kubernetes manifests per environment
Kubernetes     →  run and schedule the pods
HPA / KEDA     →  change the replica count on a signal
DaemonSet      →  node agents, alongside — not the app
```

Each layer hands one artifact to the next. **Nothing skips a layer.**

---

## 1. Terraform — infrastructure only

Terraform stops at "there is a cluster." It does not deploy the app.

```hcl
resource "proxmox_virtual_environment_vm" "k3s_node" {
  count     = var.node_count          # dev 1, stage 2, prod 3
  node_name = "pve2"
  cpu    { cores = var.cores }
  memory { dedicated = var.memory_mb }
}
```

**Why not use Terraform to deploy the app too?** Because Terraform's model is *desired state of
infrastructure*, and a rolling application deploy is a different problem with different failure
modes. Mixing them means a bad image rollback becomes a `terraform destroy`. Keep the boundary.

---

## 2. Docker — the artifact

```dockerfile
FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py VERSION ./
USER 1000:1000
EXPOSE 8080
CMD ["python", "app.py"]
```

**This is where your `requirements.txt` belongs** — baked in at build time, not installed on a
running machine. That is the real win: today Ansible installs dependencies onto a live host, so two
hosts can drift. An image cannot drift; it is the same bytes everywhere.

**And the security win:** an image is a **scannable artifact**. Trivy or Grype reads the layers and
reports CVEs *before* it ever runs — a fifth gate, in the same shape as the four you have:

```
gitleaks → secrets      checkov → terraform      policy → the plan      trivy → the image
```

---

## 3. Helm — one chart, three environments

Helm is a templating and release tool **for Kubernetes**. Without a cluster it has nothing to talk to.

```
chart/
├── Chart.yaml
├── values.yaml            # shared defaults
├── values-dev.yaml        # replicas: 1
├── values-stage.yaml      # replicas: 2
├── values-prod.yaml       # replicas: 3, HPA on
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    └── hpa.yaml
```

```bash
helm upgrade --install inspection ./chart \
  -f chart/values-prod.yaml \
  --set image.tag=1.2.0 \
  --namespace prod --atomic --timeout 5m
```

`--atomic` rolls back automatically if the release fails. That is Helm's real value: **a release is
a transaction**, not a sequence of `kubectl apply` you hope all succeed.

This maps exactly onto what you have now — `values-<env>.yaml` is the same idea as your per-environment
Terraform tfvars.

---

## 4. Kubernetes — the Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: inspection-service }
spec:
  replicas: {{ .Values.replicas }}
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: app
          image: "{{ .Values.image.repo }}:{{ .Values.image.tag }}"   # never :latest
          readinessProbe:
            httpGet: { path: /health, port: 8080 }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          resources:
            requests: { cpu: 100m, memory: 128Mi }    # required for HPA to work
            limits:   { cpu: 500m, memory: 256Mi }
```

Every `securityContext` line is something Checkov already checks. **Your blocking list barely
changes — only what it points at.**

---

## 5. Autoscaling — and the caveat worth volunteering

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  scaleTargetRef: { kind: Deployment, name: inspection-service }
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
```

Three things people miss:

1. **`resources.requests` is mandatory.** "70% CPU" means 70% *of the request*. No request, no
   autoscaling — the HPA silently does nothing.
2. **CPU is usually the wrong signal.** For a claims API the real signal is queue depth or p95
   latency. That means **KEDA** or a custom metrics adapter, which is a bigger commitment than the
   YAML suggests.
3. **It changes your security model.** Pods can now appear with no human in the loop, so CI-time
   policy is no longer sufficient. You need **admission control** — OPA Gatekeeper or Kyverno —
   enforcing policy *at the cluster*, not just before merge.

> Point 3 is the one worth saying aloud. It shows you understand autoscaling as a security change,
> not just a scaling feature.

---

## 6. Where a DaemonSet actually belongs

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata: { name: log-shipper }
spec:
  template:
    spec:
      containers:
        - name: vector
          volumeMounts:
            - { name: varlog, mountPath: /var/log, readOnly: true }
```

One per node, reading node-local logs. **Alongside** the application, never as the application.

---

## What this changes about the pipeline: almost nothing

| Layer | Changes moving to Kubernetes? |
|---|---|
| gitleaks, full history | no |
| Checkov, environment-tiered blocking list | no — different resources, same shape |
| AI triage that explains but never decides | no |
| SOPS per-environment keys | no — or External Secrets Operator |
| Remote state with locking | no |
| Approval gates on stage and prod | no |
| Runner isolation per environment | no |
| **The apply step** | **yes** — `helm upgrade` instead of `terraform apply` |
| **Runtime enforcement** | **added** — admission control |

**Eight of nine layers unchanged.** That is the argument for having built the pipeline decoupled from
the orchestrator, and it is a better answer than a rushed cluster.

---

## The order I would actually do it

1. **Trivy as a fifth gate** — works today, no Kubernetes needed
2. **Containerise** — `requirements.txt` moves into the image, drift disappears
3. **k3s on the Proxmox host** — one node, prove the manifests
4. **Helm chart with per-environment values** — mirrors the tfvars you already have
5. **Move dev only** — leave stage and prod alone until dev is boring
6. **Admission control** — Gatekeeper or Kyverno, *before* autoscaling
7. **Autoscaling last** — on the right metric, not CPU

Steps 1 and 2 are worth doing whether or not 3–7 ever happen. That is usually the sign of a sensible
order.

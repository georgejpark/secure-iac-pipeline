# How I would evolve this

What is built is deliberately small. This is what I would do next, in order, and why that order.

---

## The question you will probably be asked

> *"Why not Kubernetes?"*

> "Because the subject here is the security pipeline, and containers-in-containers would have added a
> registry, image builds and an orchestrator to demonstrate gates that need none of them. The gates
> are the transferable part. If you run Kubernetes, the same four gates sit in front of your
> manifests instead of my Terraform — it's the same pattern with a different apply step.
>
> That said, I know exactly what moving this to Kubernetes looks like, and there's one thing about it
> that changes the security model rather than just the deployment model."

Then the section below.

---

## Step 1 — Containerise the application

Today Ansible copies Python onto a machine and systemd runs it. The first move is an image:

```dockerfile
FROM python:3.13-slim
WORKDIR /app
COPY app.py VERSION ./
USER 1000:1000
EXPOSE 8080
CMD ["python", "app.py"]
```

**What this changes for security, which is the interesting part:** the artifact becomes immutable and
*scannable*. A container image can be scanned for CVEs before it ever runs — Trivy or Grype as a
**fifth gate**, in exactly the same shape as the four that exist:

```
gitleaks   → secrets
checkov    → infrastructure
policy     → the plan
trivy      → the image        ← new
```

That is the real argument for containers here. Not density, not portability — **a scannable
artifact**.

---

## Step 2 — Deployment, not DaemonSet

Worth being precise, because these are often confused:

| Primitive | Runs | Use it for |
|---|---|---|
| **Deployment** | N replicas, scheduler decides placement | a web service — **this one** |
| **DaemonSet** | exactly one per node | node agents: log shippers, metrics, CNI |
| **StatefulSet** | ordered, stable identity + storage | databases, queues |

The inspection service is a stateless HTTP service, so it is a **Deployment**. A DaemonSet would tie
replica count to node count, which is not what you want for a web tier.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inspection-service
spec:
  replicas: 2                       # prod. dev would be 1
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: app
          image: registry.internal/inspection:1.0.0    # never :latest
          ports: [{ containerPort: 8080 }]
          readinessProbe:
            httpGet: { path: /health, port: 8080 }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
```

Every `securityContext` line there is something Checkov already checks. The blocking list barely
changes — only what it points at.

---

## Step 3 — Autoscaling, and the honest caveat

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

**The caveat worth volunteering:** an HPA needs `resources.requests` set to mean anything, and it
scales on the wrong signal by default. CPU is a proxy. For a claims API the real signal is usually
queue depth or p95 latency, which means KEDA or a custom metric — and that is a bigger commitment
than the four lines of YAML suggest.

**And it changes the security model.** Autoscaling means pods appearing without a human in the loop,
so the admission gate has to be as good as the pipeline gate. That is where **OPA Gatekeeper** or
**Kyverno** comes in: policy enforced by the cluster at admission, not only by CI before merge.

That is the shift I would actually be arguing for. Not "Kubernetes is better" — but **CI-time policy
becomes insufficient the moment workloads can appear without a merge.**

---

## Step 4 — What stays exactly the same

This is the point worth making at the end:

| Layer | Changes? |
|---|---|
| gitleaks, full history | **no** |
| Checkov, environment-tiered blocking list | **no** — different resources, same policy shape |
| AI triage that explains but never decides | **no** |
| SOPS, one key per environment | **no** — or External Secrets Operator |
| Terraform state in Postgres with locking | **no** |
| Approval gates on stage and prod | **no** |
| Runner isolation per environment | **no** |
| The apply step | **yes** — `kubectl apply` instead of `terraform apply` |
| Runtime enforcement | **added** — admission control |

**Eight of nine layers are unchanged.** That is the argument for having built it this way: the
pipeline is not coupled to the orchestrator.

---

## The order I would actually do it

1. **Trivy as a fifth gate** — works today, no Kubernetes required, real value immediately
2. **Containerise** — get a scannable artifact
3. **k3s on the Proxmox host** — one node, prove the manifests
4. **Move dev only** — leave stage and prod on the current path until dev is boring
5. **Admission control** — Gatekeeper or Kyverno *before* autoscaling, not after
6. **Autoscaling last** — and on the right metric, not CPU

Steps 1 and 2 are worth doing regardless of whether steps 3–6 ever happen. That is usually the sign
of a sensible order.

---

## What I would not do

- **Kubernetes for four containers on one host.** The operational cost exceeds the benefit until
  there is a real scheduling or multi-tenancy problem to solve.
- **Autoscaling before admission control.** Workloads appearing without a human, with no runtime
  policy, is strictly worse than what exists now.
- **`imagePullPolicy: Always` with `:latest`.** Reintroduces exactly the "what is actually deployed"
  ambiguity the version-asserting healthcheck was built to remove.

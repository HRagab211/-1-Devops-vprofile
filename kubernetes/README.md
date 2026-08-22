# VProfile on Kubernetes -- minimal lab deployment

A direct translation of this repository's Docker Compose stack onto a kubeadm Vagrant
cluster (one control plane, two workers). Plain Kubernetes objects only: no Helm, no
operators, no Ingress, no TLS, no autoscaling, no monitoring, no service mesh.

## Architecture

```
User
  |
  v  http://<NODE_IP>:30080/
Service vprofile-nginx        (NodePort 30080 -> 80)
  |
  v
Deployment vprofile-nginx     (nginx:1.27-alpine, proxies to vprofile-app:8080)
  |
  v
Service vprofile-app          (ClusterIP 8080)
  |
  v
Deployment vprofile-app       (Tomcat 10.1 / JRE 17, ROOT.war built from this repo)
  |
  +--> Service vprofile-db         (ClusterIP 3306)  -> StatefulSet mysql:8.0.43 + PVC
  +--> Service vprofile-cache      (ClusterIP 11211) -> Deployment memcached:1.6-alpine
  +--> Service vprofile-rabbitmq   (ClusterIP 5672)  -> Deployment rabbitmq:3.13-management-alpine
```

Everything lives in the namespace `vprofile`. Nothing here touches `kube-system` or the
`helm` namespace where Jenkins runs.

Elasticsearch is intentionally **not** deployed. `ElasticSearchController` builds its client
per request and no bean constructs one at startup, so nothing dials it during boot. The four
`ELASTICSEARCH_*` keys still appear in the ConfigMap because `beans/Components.java` declares
`@Value("${elasticsearch.*}")` with no defaults and the placeholder configurer is not
`ignore-unresolvable` -- removing them breaks Spring context startup.

## Resources

| File | Resources |
|---|---|
| `namespace.yaml` | Namespace `vprofile` |
| `secret.yaml` | Secret `vprofile-secret` (lab credentials) |
| `app-configmap.yaml` | ConfigMap `vprofile-config` |
| `mysql-init-configmap.yaml` | ConfigMap `vprofile-db-init` (generated from `src/main/resources/db_backup.sql`) |
| `mysql-statefulset.yaml` | StatefulSet `vprofile-db` + its `data` PVC (via `volumeClaimTemplates`) |
| `mysql-service.yaml` | Service `vprofile-db` (ClusterIP) |
| `memcached.yaml` | Deployment + Service `vprofile-cache` |
| `rabbitmq.yaml` | Deployment + Service `vprofile-rabbitmq` |
| `app-deployment.yaml` | Deployment `vprofile-app` |
| `app-service.yaml` | Service `vprofile-app` (ClusterIP) |
| `nginx-configmap.yaml` | ConfigMap `vprofile-nginx-config` |
| `nginx-deployment.yaml` | Deployment `vprofile-nginx` |
| `nginx-service.yaml` | Service `vprofile-nginx` (NodePort 30080) |
| `kustomization.yaml` | Aggregates the above for `kubectl apply -k` |

There is no standalone `mysql-pvc.yaml`: a StatefulSet must own its storage through
`volumeClaimTemplates`, which is what keeps the claim bound to the pod identity `vprofile-db-0`.

## STEP 0 -- you must replace the application image placeholder

`app-deployment.yaml` ships with a deliberate placeholder:

```yaml
image: YOUR_REGISTRY/YOUR_VPROFILE_IMAGE:YOUR_TAG
```

**Applying this manifest before replacing it will fail.** The pod will report
`InvalidImageName` (the placeholder is not a parseable reference) or `ImagePullBackOff`.
That is expected, not a bug.

Build, tag and push the image from this repository first:

```bash
# from the repository root
docker build -t vprofile-app:lab \
  --build-arg GIT_SHA="$(git rev-parse HEAD)" \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" .

docker tag vprofile-app:lab YOUR_REGISTRY/YOUR_VPROFILE_IMAGE:YOUR_TAG
docker push YOUR_REGISTRY/YOUR_VPROFILE_IMAGE:YOUR_TAG
```

Then edit the one line in `app-deployment.yaml` and apply:

```bash
kubectl apply -k kubernetes/
```

`imagePullPolicy: IfNotPresent` is used, so a node that already has the image will not
re-pull it. Note that on a kubeadm cluster the container runtime is containerd, not the
Docker daemon -- an image built locally with `docker build` is **not** visible to the
kubelet. Either push it to a registry both workers can reach, or import it into containerd
on every worker (`docker save ... | vagrant ssh worker -c 'sudo ctr -n k8s.io images import -'`).

**Private registry?** No `imagePullSecrets` is created, because an unused Secret is just
clutter. If your registry needs authentication, add one:

```bash
kubectl create secret docker-registry regcred -n vprofile \
  --docker-server=YOUR_REGISTRY --docker-username=... --docker-password=...
```

and reference it under `spec.template.spec` in `app-deployment.yaml`:

```yaml
      imagePullSecrets:
        - name: regcred
```

## Deployment order

Kubernetes reconciles continuously, so `kubectl apply -k kubernetes/` in one shot is fine --
the app pod will simply restart until its dependencies answer. The ordered walkthrough below
is the one to follow while learning, because each step has an observable result.

```bash
# 1. Verify the cluster
kubectl get nodes -o wide
kubectl get storageclass          # expect: local-path
kubectl get services --all-namespaces | grep -i nodeport   # confirm 30080 is free

# 2. Namespace
kubectl apply -f kubernetes/namespace.yaml

# 3. Configuration and credentials
kubectl apply -f kubernetes/secret.yaml
kubectl apply -f kubernetes/app-configmap.yaml
kubectl apply -f kubernetes/mysql-init-configmap.yaml

# 4-5. MySQL, and wait for it
kubectl apply -f kubernetes/mysql-service.yaml -f kubernetes/mysql-statefulset.yaml
kubectl rollout status statefulset/vprofile-db -n vprofile --timeout=10m

# 6-7. Memcached and RabbitMQ, and wait for them
kubectl apply -f kubernetes/memcached.yaml -f kubernetes/rabbitmq.yaml
kubectl rollout status deployment/vprofile-cache -n vprofile
kubectl rollout status deployment/vprofile-rabbitmq -n vprofile

# 8. CONFIRM the image placeholder in app-deployment.yaml has been replaced
grep image: kubernetes/app-deployment.yaml

# 9. Application
kubectl apply -f kubernetes/app-deployment.yaml -f kubernetes/app-service.yaml
kubectl rollout status deployment/vprofile-app -n vprofile --timeout=10m

# 10. Nginx
kubectl apply -f kubernetes/nginx-configmap.yaml \
              -f kubernetes/nginx-deployment.yaml \
              -f kubernetes/nginx-service.yaml
kubectl rollout status deployment/vprofile-nginx -n vprofile

# 11. Verify the NodePort
kubectl get svc vprofile-nginx -n vprofile
```

## Access URL

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NODE_PORT=$(kubectl get svc vprofile-nginx -n vprofile -o jsonpath='{.spec.ports[0].nodePort}')
echo "http://${NODE_IP}:${NODE_PORT}/"
```

Every node proxies a NodePort, so any node IP works regardless of where the nginx pod landed.
`GET /` is the login page. Seed accounts come from `db_backup.sql` (e.g. `admin_vp`).

RabbitMQ's management UI is deliberately cluster-internal:

```bash
kubectl port-forward -n vprofile svc/vprofile-rabbitmq 15672:15672
# then open http://localhost:15672/
```

## Verification

```bash
kubectl get all -n vprofile
kubectl get pvc,pv -n vprofile
kubectl get configmap,secret -n vprofile
kubectl get events -n vprofile --sort-by='.lastTimestamp'
```

Check each of these:

```bash
# 1-2. PVC Bound, MySQL ready
kubectl get pvc -n vprofile                     # data-vprofile-db-0 -> Bound
kubectl get pod vprofile-db-0 -n vprofile       # 1/1 Running

# 3-4. Database and tables exist
kubectl exec -n vprofile vprofile-db-0 -- \
  mysql -uadmin -p"$(kubectl get secret vprofile-secret -n vprofile -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)" \
  -e 'SHOW TABLES; SELECT COUNT(*) FROM user;' accounts
# expect: role, user, user_role -- and 10 seed users

# 5. Memcached reachable through its Service
kubectl run -n vprofile nettest --rm -it --restart=Never --image=busybox:1.36 -- \
  sh -c 'echo version | nc vprofile-cache 11211'

# 6. RabbitMQ reachable through its Service
kubectl exec -n vprofile deployment/vprofile-rabbitmq -- rabbitmq-diagnostics check_port_connectivity

# 7-8. Application ready, and connected to its dependencies
kubectl get pods -n vprofile -l app.kubernetes.io/name=vprofile-app
kubectl logs -n vprofile deployment/vprofile-app | head -40
# entrypoint lines confirm each dependency: "vprofile-db:3306 is accepting connections."

# 9-10. Nginx proxies, login page loads through the NodePort
curl -I "http://${NODE_IP}:${NODE_PORT}/nginx-health"
curl -I "http://${NODE_IP}:${NODE_PORT}/"

# 11. Data survives an application restart
kubectl rollout restart deployment/vprofile-app -n vprofile
kubectl rollout status deployment/vprofile-app -n vprofile
# then re-run the SHOW TABLES check above -- the row counts must be unchanged

# 12. No pod stuck in a bad phase
kubectl get pods -n vprofile
```

## Day-to-day operations

```bash
# Logs
kubectl logs -n vprofile deployment/vprofile-app
kubectl logs -n vprofile statefulset/vprofile-db
kubectl logs -n vprofile deployment/vprofile-rabbitmq
kubectl logs -n vprofile deployment/vprofile-nginx
kubectl logs -n vprofile deployment/vprofile-app --previous   # after a crash
kubectl describe pod -n vprofile <pod-name>
kubectl get events -n vprofile --sort-by='.lastTimestamp'

# Restart safely (rolling, no data loss)
kubectl rollout restart deployment/vprofile-app -n vprofile
kubectl rollout restart deployment/vprofile-nginx -n vprofile
# nginx must also be restarted after editing nginx-configmap.yaml: the mounted file
# updates, but nginx does not reload on its own.

# Update the application image
kubectl set image deployment/vprofile-app \
  app=YOUR_REGISTRY/YOUR_VPROFILE_IMAGE:YOUR_TAG \
  -n vprofile
kubectl rollout status deployment/vprofile-app -n vprofile

# Roll back
kubectl rollout history deployment/vprofile-app -n vprofile
kubectl rollout undo deployment/vprofile-app -n vprofile
kubectl rollout undo deployment/vprofile-app --to-revision=2 -n vprofile

# Delete the stateless parts only -- MySQL, its PVC and your data are untouched
kubectl delete deployment vprofile-app vprofile-nginx vprofile-cache vprofile-rabbitmq -n vprofile
kubectl delete service vprofile-app vprofile-nginx vprofile-cache vprofile-rabbitmq -n vprofile
```

## Storage, and how to lose your data

MySQL claims 5Gi `ReadWriteOnce` from the `local-path` StorageClass. local-path provisions a
directory **on the worker node where the pod first ran**, and the resulting PV carries node
affinity for that node. Consequences:

* `vprofile-db-0` will be scheduled back onto that same worker for as long as the PVC lives.
  Do not add manual `nodeSelector` or affinity -- the provisioner already pins it correctly.
* No other workload here is pinned. The app, nginx, cache and RabbitMQ schedule freely, and
  the control-plane taint is not tolerated by anything.
* `vagrant halt` / `vagrant up` preserves the VM disk, so the database survives.
  **`vagrant destroy` deletes the disk and the database with it.**

> **WARNING -- deleting the MySQL PVC destroys the database.**
> The init ConfigMap only runs when `/var/lib/mysql` is empty. Deleting
> `pvc/data-vprofile-db-0` therefore does not "reset" anything gracefully: it discards every
> registered user and every change, and the next start re-imports `db_backup.sql` from
> scratch. There is no backup in this lab. Take a dump first if the data matters:
>
> ```bash
> kubectl exec -n vprofile vprofile-db-0 -- \
>   mysqldump -uroot -p<root-password> accounts > accounts-backup.sql
> ```
>
> Note that `kubectl delete -k kubernetes/` deletes the *namespace*, and deleting a namespace
> deletes the PVCs inside it. Use the targeted stateless-delete commands above instead.

## Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `InvalidImageName` on `vprofile-app` | The `YOUR_REGISTRY/...` placeholder is still in `app-deployment.yaml` | Replace it (STEP 0), then re-apply |
| `ImagePullBackOff` / `ErrImagePull` | Image not pushed, tag wrong, registry unreachable, or private registry with no `imagePullSecrets`. On kubeadm, also: the image only exists in the local Docker daemon, which containerd cannot see | `kubectl describe pod` and read the pull error; push the image or add `imagePullSecrets` |
| App `CrashLoopBackOff`, logs end with `timed out ... waiting for vprofile-db:3306` | A dependency is not ready yet; the entrypoint exits 69 | Normal while MySQL initialises -- it self-heals. If it persists, check the dependency's own pod |
| App restarts before ever becoming ready | Startup probe budget exhausted (10 min) | `kubectl logs --previous`; usually a Hibernate bootstrap failure -- check `JDBC_URL` and the DB credentials |
| App 404s on every path | Spring context refresh failed, so the WAR never deployed. Never retried | Read `kubectl logs` for the root cause exception, fix config, `rollout restart` |
| PVC stuck `Pending` | No `local-path` StorageClass, or its provisioner pod is not running | `kubectl get storageclass`; `kubectl -n local-path-storage get pods` |
| MySQL never becomes ready; logs show init errors | The init ConfigMap is malformed, or the datadir already had content so init was skipped | `kubectl logs vprofile-db-0`; regenerate the ConfigMap (command in its header) |
| `Access denied for user 'admin'@'%'` | Secret changed *after* the PVC was created -- MySQL only creates users on first init | Either restore the original password in the Secret, or `ALTER USER` inside the running database |
| `Connection refused` to cache/rabbitmq in app logs | Service name or port mismatch | Compare `vprofile-config` against `kubectl get svc -n vprofile` |
| Nginx `502 Bad Gateway` | The app pod is not ready, or `vprofile-app` Service has no endpoints | `kubectl get endpoints vprofile-app -n vprofile` -- empty means the app is not passing readiness |
| `/nginx-health` works but `/` 502s | Confirms nginx is healthy and the upstream is not -- always the app side | Investigate `vprofile-app` |
| NodePort unreachable from your host | Port already taken, or the Vagrant VM's network is not routable from the host | `kubectl get svc -n vprofile`; try each node IP; check the Vagrantfile's private network |

## Configuration reference

`vprofile-config` (ConfigMap): `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_DATABASE`,
`JDBC_DRIVER_CLASS_NAME`, `JDBC_URL`, `MEMCACHED_HOST`, `MEMCACHED_PORT`,
`MEMCACHED_STANDBY_HOST`, `MEMCACHED_STANDBY_PORT`, `RABBITMQ_HOST`, `RABBITMQ_PORT`,
`ELASTICSEARCH_HOST`, `ELASTICSEARCH_PORT`, `ELASTICSEARCH_CLUSTER`, `ELASTICSEARCH_NODE`,
`LOG_LEVEL`, `APP_LOG_LEVEL`, `SPRING_LOG_LEVEL`, `HIBERNATE_LOG_LEVEL`, `WAIT_FOR_TCP`,
`WAIT_FOR_TIMEOUT`.

`vprofile-secret` (Secret) keys: `MYSQL_ROOT_PASSWORD`, `MYSQL_USER`, `MYSQL_PASSWORD`,
`RABBITMQ_USER`, `RABBITMQ_PASSWORD`. The app reads `MYSQL_USER`/`MYSQL_PASSWORD` as its JDBC
credentials and `RABBITMQ_USER`/`RABBITMQ_PASSWORD` as its AMQP credentials, so MySQL and the
application can never drift apart.

**These are throwaway lab credentials committed for reproducibility. Replace them for
anything real, and never commit the replacement.** Changing `MYSQL_PASSWORD` after the PVC
exists will not change the password inside an already-initialised database.

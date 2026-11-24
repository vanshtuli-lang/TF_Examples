# airflow-podman: Astro Runtime on existing VMs with Terraform

Installs and runs Airflow from the Astro Runtime image (including the `-chainguard` variants) on Linux VMs you already have. It works on one VM or several. Terraform connects over SSH and leaves the containers as podman quadlet units under systemd. After an apply there are no manual steps on the VM: deploys, config changes, restarts after reboot and teardown are all handled by `terraform apply` / `terraform destroy`.

It does not create VMs, networks, load balancers or databases. You provide those.

## What runs where

```
VM (systemd)
├── /etc/containers/systemd/airflow-*.container   quadlet units written by Terraform
├── /etc/airflow/airflow.env                      Airflow settings and secrets (0600 root)
└── /opt/airflow                                  base_dir
    ├── dags/      synced from <project_dir>/dags, mounted read-only
    ├── logs/      task logs
    ├── config/    SimpleAuthManager password file
    └── postgres/  only with the bundled dev database

Containers (all --network host):
  airflow-db-migrate     oneshot: airflow db migrate, runs before the others
  airflow-api-server     UI, REST API, Execution API
  airflow-scheduler      (LocalExecutor: tasks run here)
  airflow-dag-processor
  airflow-triggerer
  airflow-worker         CeleryExecutor only
  airflow-postgres       only when sql_alchemy_conn is unset (dev/test)
  airflow-redis          only for CeleryExecutor when celery_broker_url is unset (dev/test)
```

Every unit restarts on failure, starts at boot, and has a health check. A failing health check restarts the container. Logs go to journald (`journalctl -u airflow-scheduler`).

## Requirements

| Where | What |
|---|---|
| Terraform runner | Terraform 1.5+, SSH access to every VM (directly or through `ssh.bastion_host`) |
| Each VM | Linux with systemd, podman 4.6+ with quadlet (e.g. RHEL 9; Amazon Linux 2023 has no podman package), passwordless `sudo` for the SSH user (or SSH as root), `base64`, `sha256sum`, `timeout` |
| Each VM, network | Pull access to the Runtime image registry (quay.io, astrocrpublic.azurecr.io, or your mirror). With `project_dir`, the build also needs PyPI (or your index) for `requirements.txt` and the Chainguard apk repo for `packages.txt` |
| Database | Postgres 14–18 reachable from every Airflow VM, with an empty database for Airflow. The bundled Postgres container is for dev/test only |

### Tested on

Astro Runtime `3.4-1-chainguard` (Airflow 3.4.0), podman 5.x, SELinux enforcing:

- **One VM:** install, re-apply with no changes, DAG-only change, `airflow_env` change, Dockerfile rebuild and rollout, recovery after a container is killed, switching between LocalExecutor and CeleryExecutor, unreachable database (fails in about a minute with a clear error), destroy.
- **Three VMs, CeleryExecutor:** podman installed by the module, workers on different queues, task logs read across hosts, cold restart of the database host, moving components between hosts, removing a host, destroy.

Not yet covered: RHEL itself (tested on its rebuild, AlmaLinux 10), x86_64, prebuilt `image` mode, `registry_auth`, `build_netrc`, a bastion host, external Postgres or Redis.

### Things to know

- **Use the host's ECDSA key for `host_key`** (`/etc/ssh/ssh_host_ecdsa_key.pub`, or `ssh-keyscan -t ecdsa <host>`). Terraform's SSH client negotiates ECDSA, so an ed25519 key fails with `knownhosts: key mismatch`. The same error after a VM rebuild means its host keys changed; update `host_key`.
- **Hostnames don't need DNS.** Each Airflow container maps the VM hostname to its `private_ip`, so task logs and heartbeats resolve across hosts even when the hostname doesn't resolve inside containers.
- **Builds use docker format** (`podman build --format docker`), so the Runtime image's build steps run under bash with `pipefail`, as they do with Docker.

## Usage

```bash
cp examples/single-vm.tfvars.example terraform.tfvars   # edit hosts, ssh, project_dir
export TF_VAR_sql_alchemy_conn='postgresql+psycopg2://airflow:<pw>@db.example.internal:5432/airflow'
terraform init
terraform apply
terraform output api_urls
terraform output -json user_passwords
```

An apply runs four steps in order. Each step re-runs only when its inputs changed.

| Step | Resource | Does |
|---|---|---|
| 1 | `terraform_data.teardown[host]` | Nothing on create. On destroy, or when a host is removed from `hosts`, stops and removes everything this module created on that host. |
| 2 | `terraform_data.base[host]` | Checks podman. Writes `/etc/airflow/*` and the password file. Pulls images, or uploads `project_dir` and runs `podman build`. Syncs DAGs. Starts the bundled Postgres/Redis and waits until they are healthy. |
| 3 | `terraform_data.migrate` | On the first scheduler host: `airflow db check` (fails fast on DB connection problems), then `airflow db migrate`. |
| 4 | `terraform_data.airflow[host]` | Writes the component units, restarts only the ones that changed, waits for the API server health check, and confirms every unit stays up. |

## Day-2 changes

| Change | What you do | What happens on the VM |
|---|---|---|
| DAGs | Change files under `<project_dir>/dags`, then `terraform apply` | DAGs are synced in place. No rebuild, no restart. |
| `requirements.txt`, `packages.txt`, Dockerfile (Runtime upgrade) | Edit, then `terraform apply` | A new image is built and tagged with the content hash. `db migrate` runs, then the components restart on the new image. Old images are removed. |
| Airflow settings | `airflow_env` / `airflow_secret_env`, then `terraform apply` | The env file is rewritten and only the affected containers restart. |
| Users | `users`, then `terraform apply` | Passwords are generated; the API server restarts. |
| Add or move hosts and roles | Edit `hosts` | New units start; units that moved away are removed. A host taken out of `hosts` is torn down. |
| VM rebuilt with the same address | `terraform apply -replace='terraform_data.base["<host>"]' -replace='terraform_data.airflow["<host>"]'` | Everything is reinstalled on that host. |

## Images and DAGs

Choose one of these:

- **`project_dir`** (matches the manual podman guide): an Astro project with `Dockerfile`, `requirements.txt`, `packages.txt` and `dags/`.
  - The project is uploaded and built on every Airflow VM as `localhost/airflow-runtime:<hash>`.
  - `dags/` is mounted from the host, so DAG changes don't need a rebuild.
  - In CI, check out the DAG repo and point `project_dir` at it. Anything in the folder is uploaded, so keep large unrelated files out.
- **`image`**: a prebuilt, scanned image from your registry. With `dags_dir` set, that folder is synced and mounted; without it, the DAGs in the image are used. Use immutable tags. An image that already exists on the host is not pulled again.

**Private index or registry:**
- For a private Python index, put an `--index-url` line in `requirements.txt` and pass credentials as `.netrc` content in `build_netrc`. The Runtime ONBUILD step mounts it as the `netrc` build secret.
- For a private registry, set `registry_auth`. It is written to `/etc/airflow/registry-auth.json` and used for pulls and builds.

**Chainguard images:**
- `packages.txt` takes Wolfi/apk package names, not Debian names.
- The image has no `id`, `curl` or `apk` at run time. Add whatever your BashOperators call to `packages.txt`.

## Single VM vs multiple VMs

**Single VM.** Leave `roles` unset and everything runs on the one host. Services talk over `127.0.0.1`, and only `api_server_port` needs to be reachable by users.

**Multiple VMs.** Set `roles` on every host, and use `executor = "CeleryExecutor"` when you add worker hosts.
- `AIRFLOW__CORE__HOSTNAME_CALLABLE` is set to the host IP, and each Airflow container maps the VM hostname to `private_ip`, so task logs and job heartbeats resolve across hosts without DNS.
- Proxy variables in the SSH session (`HTTP_PROXY` and similar) reach `podman build`, but the running containers don't inherit them. If DAGs need a proxy, set `HTTPS_PROXY` and `NO_PROXY` through `airflow_env`. `NO_PROXY` must include the other hosts' private IPs, so Execution API and log calls don't go through the proxy.
- The Execution API URL defaults to the local API server when the host has one, otherwise the first api-server host. Override it with `execution_api_server_url` when there's a load balancer.
- `terraform output inbound_ports` lists what each host must accept from which other hosts. Opening those ports is the network team's job; this module does not manage host or cloud firewalls.
- Task logs stay on the host that ran the task and are served to the UI on port 8793 (8794 for the triggerer). For durable logs, configure remote logging to S3 through `airflow_env` (the Amazon provider goes in `requirements.txt`).

## Security notes

- Generated secrets (Fernet key, JWT secret, API secret key, user passwords, bundled DB/Redis passwords) are in Terraform state. Use an encrypted backend with restricted access (see `versions.tf`).
- On the VM, secrets live in root-only files under `/etc/airflow`, a podman secret (Redis), and the password file (container user, `0600`). The rendered apply scripts carry secrets and are deleted right after they run. Nothing goes through cloud-init user data.
- Set `host_key` on every host so Terraform verifies the VM it connects to. Use the ECDSA host key (see "Things to know").
- To reuse an existing database with encrypted connections, set `fernet_key` to its current key.
- Auth is Airflow's SimpleAuthManager. FAB isn't in the Runtime image, so SSO/LDAP needs extra work.

## Destroy

`terraform destroy` stops and removes the units, containers, podman secret, built images, `/etc/airflow` and the staging directory on every host. `base_dir` (DAGs, logs, bundled DB data) is kept unless `purge_data_on_destroy = true`. A customer-provided database is never touched.

## Files

| File | Purpose |
|---|---|
| `variables.tf` | Inputs |
| `locals.tf` | Placement, Airflow config, quadlet unit and script rendering |
| `secrets.tf` | Generated secrets |
| `main.tf` | The four SSH steps |
| `outputs.tf` | URLs, passwords, placement, ports |
| `templates/apply.sh.tftpl` | Idempotent per-step script (runs as root on the VM) |
| `templates/unit.container.tftpl` | Quadlet unit |
| `templates/teardown.sh.tftpl` | Destroy-time cleanup |
| `examples/` | tfvars examples and a minimal Astro project with a smoke-test DAG |

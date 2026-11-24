# Terraform: Airflow on VMs (Astro Runtime 3.4 Chainguard + Podman)

Three Terraform stacks, applied in order. Each has its own state.

| Folder | Providers | What it does | Needed when |
|---|---|---|---|
| [`infra/`](infra/) | `hashicorp/aws`, `hashicorp/random` | EC2 (RHEL 9), EFS, PostgreSQL RDS, load balancer. User data only installs Podman and mounts EFS over NFS. | Only if you don't already have VMs, a database and a load balancer |
| [`airflow-podman/`](airflow-podman/README.md) | `hashicorp/random` | Installs and runs Airflow on one or more VMs over SSH: image build, DAG sync, DB migration, every component as a systemd (quadlet) unit, upgrades, teardown | Always |
| [`airflow-config/`](airflow-config/README.md) | `Mastercard/restapi`, `hashicorp/external` | Airflow connections, variables and pools through the REST API, with drift detection | Always |

```
infra (optional)            VMs, network, Postgres, load balancer
   │  instance IP, sql_alchemy_conn, airflow_url
   ▼
airflow-podman              Airflow running, admin password in outputs
   │  airflow_url, admin password
   ▼
airflow-config              connections, variables, pools
```

## Which tool configures what

| Layer | Configured by | How changes reach it |
|---|---|---|
| AWS resources | `infra/` (or your own Terraform) | `terraform apply` |
| Podman on the VM | `infra/user_data.sh.tftpl` (first boot), or your VM image | Install Podman 4.6+ once; `airflow-podman` checks the version |
| Airflow containers, image, DAGs, `airflow.cfg` settings | `airflow-podman/` over SSH | `terraform apply`: re-runs only the steps whose inputs changed, never replaces the VM |
| Connections, variables, pools | `airflow-config/` | `terraform apply`: POST/PATCH/DELETE on `/api/v2` |
| Airflow API token | `external` data source in `airflow-config/` | Fetched on every plan from `POST /auth/token` |

## Before you start

- Terraform 1.5+ and `python3` where Terraform runs.
- SSH from where Terraform runs to every VM (port 22, directly or through a bastion), as a user with passwordless `sudo`.
- VMs: Linux with systemd and Podman 4.6+ with quadlet (see "Operating system" below). Outbound access to `quay.io` (or your registry mirror) and PyPI.
- Postgres 14–18 with an empty `airflow` database.
- An Astro project (`Dockerfile`, `requirements.txt`, `packages.txt`, `dags/`). `airflow-podman/examples/astro-project` is a minimal one.

## Operating system

`infra/` launches the latest **RHEL 9** AMI from Red Hat (owner `309956199498`). Its AppStream repo has podman 4.6+ with quadlet, and SELinux is enforcing; the EFS mount is labelled for containers. Override with `ami_id` (for example a hardened company image) as long as it is dnf-based and can install `podman` 4.6+ and `nfs-utils`. The default login user is `ec2-user`.

**Amazon Linux 2023 is not supported.** Podman is not in the AL2023 repositories, so first boot fails before EFS is mounted, and `airflow-podman` then stops with "podman is not installed".

EFS is mounted with the kernel NFS client (`nfs4`, `nfsvers=4.1`, AWS's recommended options) because RHEL has no `amazon-efs-utils` package. Traffic to EFS is not TLS-wrapped; the EFS security group only accepts NFS from the Airflow instance.

## Step 1 (optional): AWS infrastructure (`infra/`)

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # vpc_id, subnets, allowed_cidrs, key_name, ssh_allowed_cidrs
terraform init && terraform apply
terraform output -raw airflow_podman_tfvars    # paste into ../airflow-podman/terraform.tfvars
export TF_VAR_sql_alchemy_conn="$(terraform output -raw sql_alchemy_conn)"
```

## Step 2: Airflow (`airflow-podman/`)

```bash
cd ../airflow-podman
cp examples/single-vm.tfvars.example terraform.tfvars   # or the output from step 1
terraform init && terraform apply
terraform output api_urls
export AIRFLOW_PASSWORD="$(terraform output -json user_passwords | python3 -c 'import json,sys; print(json.load(sys.stdin)["admin"])')"
```

For several VMs and CeleryExecutor, start from `examples/multi-vm.tfvars.example`. See [airflow-podman/README.md](airflow-podman/README.md) for inputs, day-2 changes and what has been tested.

## Step 3: connections, variables, pools (`airflow-config/`)

```bash
cd ../airflow-config
cp terraform.tfvars.example terraform.tfvars   # airflow_url, connections, variables, pools
export TF_VAR_connection_secrets='{"warehouse": {"password": "..."}}'
terraform init && terraform apply
```

See [airflow-config/README.md](airflow-config/README.md) for drift behaviour, importing existing objects and the restapi version pin.

## Everyday use

| I want to… | Do this |
|---|---|
| Deploy DAG changes | Change `dags/` in the project, `terraform apply` in `airflow-podman` (synced, no restart) |
| Add a Python/OS package or upgrade the Runtime tag | Edit `requirements.txt` / `packages.txt` / `Dockerfile`, `terraform apply` in `airflow-podman` (rebuild, migrate, restart) |
| Change an Airflow setting | `airflow_env` in `airflow-podman`, `terraform apply` |
| Add or change connections, variables, pools | `airflow-config`, `terraform apply` |
| Restart a component | On the VM: `sudo systemctl restart airflow-scheduler` |
| See logs | `journalctl -u airflow-scheduler -f` |
| Run an Airflow CLI command | `sudo podman exec -it airflow-scheduler airflow dags list` |

## Tear down

```bash
cd airflow-config && terraform destroy
cd ../airflow-podman && terraform destroy
cd ../infra   # set db_deletion_protection = false, terraform apply, then:
terraform destroy
```

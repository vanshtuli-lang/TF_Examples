# Airflow dev environment on EC2 (Terraform)

One Terraform stack that builds an Airflow **development** environment on AWS: one EC2 instance running the Astro Runtime image, a PostgreSQL RDS database, optional EFS for DAGs and logs, and an optional load balancer for the UI.

The instance sets itself up at first boot (EC2 user data): it installs Podman or Docker, pulls the image and starts Airflow as systemd services. There is no SSH step and no inbound port 22; use AWS Systems Manager (Session Manager) for a shell.

It is a reference starting point, not an approved design. See [Decisions to confirm](#decisions-to-confirm-before-you-apply) before applying in a real account.

## What you get

```
users ──► load balancer (optional, 80/443) ──► EC2 :8080 ──► RDS PostgreSQL :5432
                                                │
                                                └──► EFS at /opt/airflow (optional): dags/, logs/

EC2 (RHEL 9), each Airflow component is a container run by a systemd service:
  airflow-db-migrate      runs "airflow db migrate" once per boot, before the others
  airflow-api-server      UI and REST API on port 8080
  airflow-scheduler       LocalExecutor: tasks run inside this container
  airflow-dag-processor   parses DAG files
  airflow-triggerer       deferrable operators

Secrets (DB connection, Fernet key, JWT secret, admin password) are SSM Parameter Store
SecureStrings. The instance reads them at boot into /etc/airflow/airflow.env (root, 0600).
```

**Deliberately left out** to keep the first setup small:

| Not included | Why | When to add it |
|---|---|---|
| Redis, Celery workers | LocalExecutor needs only Postgres. Tasks run on the one instance. | If you outgrow one VM: switch to CeleryExecutor, add a broker (e.g. ElastiCache) and worker instances. |
| Flower | It only monitors Celery workers, so it does nothing with LocalExecutor. | Together with CeleryExecutor. |
| SSH-based deploys, auto-scaling, multiple instances | One dev instance doesn't need them. | UAT/prod. |
| Connections/variables as Terraform resources | Airflow reads `AIRFLOW_CONN_*` / `AIRFLOW_VAR_*` environment variables, which this stack already supports through SSM (see [Day-to-day](#day-to-day)). | If you want drift detection on them. |

## Decisions to confirm before you apply

These are not settled. The repo picks a default for each so it can run, and each is one setting to change.

| Decision | Default here | Change with |
|---|---|---|
| OS / AMI | Latest RHEL 9 from Red Hat | `ami_id` (e.g. your hardened golden image). Amazon Linux 2023 works only with Docker: it has no podman package. |
| Container runtime: Podman or Docker | Podman | `container_runtime = "docker"` |
| Image and registry (security scanning: JFrog / Quay / Harness?) | `quay.io/astronomer/astro-runtime:3.4-1-chainguard` | `airflow_image`. Use the scanned internal copy, pinned by digest (`...@sha256:...`). ECR login is automatic; other private registries need a login step added to `user_data.sh.tftpl`. Confirm approval for the image actually deployed: earlier approval was for open-source Airflow on EC2. |
| Executor | LocalExecutor (no Redis) | See "Deliberately left out" |
| RDS | PostgreSQL 16, `db.t4g.medium`, 50 GB, single-AZ, 7-day backups, deletion protection on | `db_*` variables, `rds.tf` |
| EFS | On | `create_efs = false` puts `/opt/airflow` on the root disk (lost if the instance is replaced) |
| Load balancer / URL | On, internal, HTTP | `create_load_balancer`, `alb_internal`, `certificate_arn` (HTTPS), `hostname` |
| Account, region, VPC, subnets | Placeholders | `terraform.tfvars` |
| Terraform state, CI, IAM boundaries, logging | Local state | `versions.tf` has an S3 backend block. Add any required permission boundary or tags. |

**Network needs.** The instance's private subnet must reach, through NAT or VPC endpoints: the OS package repos (Red Hat RHUI for RHEL; also `download.docker.com` for Docker on RHEL), the image registry, `awscli.amazonaws.com` (RHEL only, to install the AWS CLI), and the SSM, EC2 messages, ECR and RDS endpoints. If any of these are blocked, bake the packages into your AMI.

## Deploy

Requirements where you run Terraform: Terraform 1.5+, AWS credentials for the account, and the AWS CLI with the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

```bash
cd airflow-ec2-terraform
cp terraform.tfvars.example terraform.tfvars   # fill in VPC, subnets, CIDRs, image
terraform init
terraform plan        # read it: see "Safe re-runs" below
terraform apply
```

First boot takes about 5–10 minutes (packages, image pull, database migration). Then:

```bash
terraform output airflow_url
$(terraform output -raw admin_password_command)    # password for user "admin"
```

No load balancer (`create_load_balancer = false`)? Forward the UI to your laptop and open http://localhost:8080:

```bash
$(terraform output -raw port_forward_command)
```

### Check it worked

```bash
$(terraform output -raw connect_command)      # shell on the instance
sudo tail -n 50 /var/log/airflow-bootstrap.log # ends with "Airflow is up"
systemctl status 'airflow-*' --no-pager
```

All four services (`api-server`, `scheduler`, `dag-processor`, `triggerer`) should be `active (running)`, and `airflow-db-migrate` `active (exited)`.

## Safe re-runs

- **`terraform apply` never replaces the instance on its own.** A new RHEL release, an edit to `user_data.sh.tftpl`, or a new `airflow_image` is ignored for the existing instance (`ignore_changes` in `ec2.tf`). This protects an instance you are debugging.
- To roll out such a change, replace the instance on purpose. The database (RDS) and DAGs/logs (EFS) are kept:
  ```bash
  terraform apply -replace=aws_instance.airflow
  ```
- Always read the plan. If it says `must be replaced` or `destroy` for something you want to keep, stop.
- This stack only manages resources it created. It does not touch an existing test instance (for example the one used for the DAG-processor investigation) unless you `terraform import` it, which you should not.

## Day-to-day

Run these on the instance (`$(terraform output -raw connect_command)`, then `sudo -i`).

| I want to… | Do this |
|---|---|
| Add or update DAGs | Put files in `/opt/airflow/dags` (on EFS). For example `git clone <dag repo> /opt/airflow/dags` once, then `git -C /opt/airflow/dags pull`. No restart needed. |
| See logs | `journalctl -u airflow-dag-processor -f` (any component). Task logs: `/opt/airflow/logs`. |
| Restart a component | `systemctl restart airflow-scheduler` |
| Run an Airflow CLI command | `podman exec -it airflow-scheduler airflow dags list` (or `docker exec`) |
| Change an Airflow setting | Add it to `airflow_env` in `terraform.tfvars`, `terraform apply`, then replace the instance (see "Safe re-runs"). For a quick test, edit `/etc/airflow/airflow.env` and restart the services. |
| Add a secret setting or a connection | Add an SSM SecureString named `/<name>/env/<VARIABLE>`, e.g. `/airflow-dev/env/AIRFLOW_CONN_WAREHOUSE` (an `aws_ssm_parameter` resource in Terraform). Then re-run the bootstrap: `bash /var/lib/cloud/instance/scripts/part-001`. |
| Upgrade the image | Change `airflow_image`, `terraform apply`, then `terraform apply -replace=aws_instance.airflow`. |
| Add Python packages / providers | Build your own image `FROM` the Runtime image with a `requirements.txt`, push it through your scanning pipeline, and set `airflow_image`. |

## Troubleshooting

| Symptom | Where to look |
|---|---|
| UI not reachable, load balancer target unhealthy | Normal for the first ~10 minutes. Then `/var/log/airflow-bootstrap.log`, and `journalctl -u airflow-api-server`. |
| Bootstrap failed | `/var/log/airflow-bootstrap.log` shows the step (package install, EFS mount, SSM read, image pull, db migrate). Fix the cause and re-run `bash /var/lib/cloud/instance/scripts/part-001`. |
| A component keeps exiting (e.g. the DAG processor) | `journalctl -u airflow-dag-processor -n 200`. systemd restarts it after 10 s, so the log shows each crash. Common causes: a DAG file that fails to import, missing Python packages in the image, database connection limits. |
| DAGs don't appear | Files must be in `/opt/airflow/dags` and readable; check `journalctl -u airflow-dag-processor` for import errors. |
| Can't open a Session Manager shell | The instance needs outbound access to the SSM endpoints, and your account must allow Session Manager. |

## Tear down

```bash
terraform apply -var db_deletion_protection=false   # unlock the database first
terraform destroy
```

This deletes the database and EFS (DAGs, logs). Take an RDS snapshot first if you need the data.

## Files

| File | What it is |
|---|---|
| `variables.tf` | Inputs, with defaults |
| `main.tf` | AMI lookup, generated secrets, SSM parameters |
| `ec2.tf` | Instance and its IAM role (Session Manager, ECR pull, read own SSM path) |
| `user_data.sh.tftpl` | First-boot bootstrap: runtime, EFS, secrets, image, systemd services |
| `rds.tf` | PostgreSQL metadata database |
| `efs.tf` | Optional EFS for DAGs and logs |
| `alb.tf` | Optional load balancer |
| `network.tf` | Security groups (no inbound SSH) |
| `outputs.tf` | URL, admin password command, Session Manager commands |
| `terraform.tfvars.example` | Example inputs |

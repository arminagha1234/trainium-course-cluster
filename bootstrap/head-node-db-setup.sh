#!/usr/bin/env bash
# head-node-db-setup.sh
#
# Runs on the head node during ParallelCluster's OnNodeStart phase, as root,
# BEFORE ParallelCluster's own cluster configuration (cookbook converge) runs.
#
# WHY OnNodeStart (and not OnNodeConfigured):
#   ParallelCluster configures Slurm accounting from its OWN chef recipe
#   `aws-parallelcluster-slurm::config_slurm_accounting`, which runs DURING the
#   PC cookbook converge — i.e. BEFORE the HeadNode OnNodeConfigured custom
#   action. That recipe starts slurmdbd and then blocks on an
#   `execute[wait for slurm database]` step that retries a connection to the
#   accounting MySQL backend and FAILS the whole converge if the DB never
#   answers. Our accounting DB is a head-node-local MariaDB at 127.0.0.1:3306
#   (SlurmSettings.Database in infra/pcluster-config.yaml), so it MUST exist and
#   accept the `slurm` user's login BEFORE that recipe runs. OnNodeConfigured is
#   too late — the converge (and thus head-node bootstrap) has already aborted.
#   Therefore this script provisions MariaDB + the `slurm` DB user in
#   OnNodeStart, which PC guarantees runs before the cookbook converge. The
#   sacctmgr QoS/association work stays in OnNodeConfigured (head-node-setup.sh
#   section 7), where slurmdbd is already up.
#
# Responsibilities:
#   1. Install + start a head-node-local MariaDB server.
#   2. Create the `slurm` MySQL user (password pulled from Secrets Manager) and
#      grant it ALL PRIVILEGES ON *.* WITH GRANT OPTION, from both localhost
#      (unix_socket) and 127.0.0.1 (TCP, how slurmdbd connects). We deliberately
#      do NOT pre-create a fixed accounting database: ParallelCluster configures
#      slurmdbd's StorageLoc to the CLUSTER NAME with dashes turned into
#      underscores (e.g. cluster `cmh-48xl-test` -> DB `cmh_48xl_test`), NOT a
#      fixed `slurm_acct_db`. Granting the slurm user ALL on *.* WITH GRANT
#      OPTION lets slurmdbd itself CREATE and manage whatever cluster-named DB PC
#      points StorageLoc at; a DB-scoped grant made slurmdbd fail with `1044
#      Access denied for user 'slurm' to database '<cluster_name>'`.
#   It does NOT touch slurmdbd/slurmctld — PC starts those itself, after
#   OnNodeStart, and creates + connects to the cluster-named accounting DB using
#   the grants this script sets up.
#
# Args (env wins, positional fallback — same style as head-node-setup.sh):
#   $1 = AWS region                     (env REGION wins)
#   $2 = Slurm accounting DB password Secrets Manager ARN
#                                       (env SLURM_DB_PASSWORD_SECRET_ARN wins)
#
# If the secret ARN is empty, accounting is OFF: this script logs and exits 0
# (no DB is provisioned, and PC's config_slurm_accounting is not engaged because
# the Database block is only rendered when the ARN is supplied).
#
# Failure model: because this runs in OnNodeStart and PC's converge WILL fail
# without a reachable DB, each critical step (mariadb install, server ping,
# secret read, provisioning SQL) is FATAL here — we fail fast with a
# "[trn-course] FATAL: ..." message rather than limp on and let the converge
# fail with a more confusing error.
#
# Idempotent: safe to re-run.

set -euo pipefail

# -----------------------------------------------------------------------------
# Inputs (env wins, positional fallback).
# -----------------------------------------------------------------------------
REGION="${REGION:-${1:?region required as \$1}}"
SLURM_DB_PASSWORD_SECRET_ARN="${SLURM_DB_PASSWORD_SECRET_ARN:-${2:-}}"

# -----------------------------------------------------------------------------
# Constants — MUST match the other side of the wiring:
#   SLURM_DB_USER `slurm`         == deploy.sh SLURM_DB_USERNAME / PC
#                                    Database.UserName (slurmdbd logs in as it).
# We intentionally do NOT define a fixed accounting DB name here: PC sets
# slurmdbd's StorageLoc to the cluster name (dashes -> underscores), so the DB
# name is neither fixed nor knowable at this point. slurmdbd creates that DB
# itself once the slurm user holds ALL PRIVILEGES ON *.* WITH GRANT OPTION
# (granted below). Env-overridable for symmetry, but deploy.sh does not set it,
# so the default is the effective contract.
# -----------------------------------------------------------------------------
SLURM_DB_USER="${SLURM_DB_USERNAME:-slurm}"

LOG=/var/log/trn-course-head-db-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "[trn-course] head-node-db-setup starting at $(date -u)"
echo "[trn-course] region=${REGION}"

# If accounting is not configured (no secret ARN), there is nothing to do and
# PC will not stand up slurmdbd, so skip cleanly.
if [[ -z "${SLURM_DB_PASSWORD_SECRET_ARN}" ]]; then
  echo "[trn-course] no accounting DB secret; skipping"
  exit 0
fi

echo "[trn-course] provisioning Slurm accounting DB user (MariaDB; user=${SLURM_DB_USER}; slurmdbd creates the cluster-named DB itself)"

# -----------------------------------------------------------------------------
# apt/dpkg lock helpers.
#
# OnNodeStart runs very early in boot, when cloud-init / unattended-upgrades
# frequently hold the dpkg/apt frontend lock. Wait the lock out (best-effort via
# fuser; if fuser is absent the wait is a no-op and we lean on the retry) and
# retry the apt operation a few times with linear backoff.
# -----------------------------------------------------------------------------
wait_for_apt_lock() {
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock         >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock    >/dev/null 2>&1; do
    if (( waited >= 300 )); then
      echo "[trn-course] apt/dpkg lock still held after ${waited}s; proceeding and relying on retry"
      return 0
    fi
    echo "[trn-course] waiting for apt/dpkg lock to release (${waited}s)..."
    sleep 5
    waited=$(( waited + 5 ))
  done
}

apt_get_retry() {
  local attempt rc=0
  export DEBIAN_FRONTEND=noninteractive
  for attempt in 1 2 3 4 5; do
    wait_for_apt_lock
    if apt-get "$@"; then
      return 0
    else
      rc=$?
      echo "[trn-course] 'apt-get $*' failed (attempt ${attempt}/5, rc=${rc}); backing off..." >&2
      sleep $(( attempt * 10 ))
    fi
  done
  return "${rc:-1}"
}

# -----------------------------------------------------------------------------
# a. Prereqs: aws (baked into the PC AMI) is required; jq is best-effort.
# -----------------------------------------------------------------------------
command -v aws >/dev/null 2>&1 \
  || { echo "[trn-course] FATAL: aws CLI not found (expected on the ParallelCluster AMI)" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  apt_get_retry update && apt_get_retry install -y jq \
    || echo "[trn-course] WARNING: jq install failed; continuing (not required by this script)" >&2
fi

# -----------------------------------------------------------------------------
# b. Install MariaDB server idempotently (skip apt entirely if already present).
# -----------------------------------------------------------------------------
if dpkg -s mariadb-server >/dev/null 2>&1; then
  echo "[trn-course] mariadb-server already installed; skipping apt"
else
  apt_get_retry update \
    || { echo "[trn-course] FATAL: 'apt-get update' failed after retries" >&2; exit 1; }
  apt_get_retry install -y mariadb-server \
    || { echo "[trn-course] FATAL: mariadb-server install failed after retries" >&2; exit 1; }
fi

# -----------------------------------------------------------------------------
# c. Enable + start MariaDB (idempotent). Unit is `mariadb` on Ubuntu; fall back
#    to `mysql`. Then wait for the server to accept connections.
# -----------------------------------------------------------------------------
systemctl enable --now mariadb 2>/dev/null \
  || systemctl enable --now mysql 2>/dev/null \
  || { echo "[trn-course] FATAL: could not enable/start MariaDB" >&2; exit 1; }

ok=""
for _i in {1..30}; do
  if mysqladmin ping >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[[ -n "${ok}" ]] || { echo "[trn-course] FATAL: MariaDB not responding after 60s" >&2; exit 1; }

# -----------------------------------------------------------------------------
# d. Fetch the DB password (plain SecretString) from Secrets Manager in REGION.
# -----------------------------------------------------------------------------
db_pw=$(aws secretsmanager get-secret-value --region "${REGION}" \
          --secret-id "${SLURM_DB_PASSWORD_SECRET_ARN}" \
          --query 'SecretString' --output text 2>/dev/null) \
  || { echo "[trn-course] FATAL: could not read Slurm DB password from ${SLURM_DB_PASSWORD_SECRET_ARN}" >&2; exit 1; }
if [[ -z "${db_pw}" || "${db_pw}" == "None" ]]; then
  echo "[trn-course] FATAL: Slurm DB password secret is empty" >&2; exit 1
fi

# -----------------------------------------------------------------------------
# e. Create the `slurm` user + grants idempotently. root connects via
#    unix_socket (default on Ubuntu MariaDB when run as root). slurmdbd connects
#    over TCP as slurm@127.0.0.1, while socket logins present as @localhost, so
#    we create + grant BOTH localhost and 127.0.0.1. The generated password
#    excludes quotes/backslash/space/$ (see SlurmDbPasswordSecret in
#    parent-stack.yaml), so embedding it in single-quoted SQL is safe.
#
#    We grant ALL PRIVILEGES ON *.* WITH GRANT OPTION rather than on one fixed
#    database: PC points slurmdbd's StorageLoc at a DB named after the cluster
#    (dashes -> underscores, e.g. `cmh-48xl-test` -> `cmh_48xl_test`), and we do
#    not pre-create or even know that name here. The *.* grant lets slurmdbd
#    CREATE and fully manage that cluster-named DB itself; a DB-scoped grant made
#    slurmdbd fail with `1044 Access denied for user 'slurm' to database
#    '<cluster_name>'`.
# -----------------------------------------------------------------------------
mysql <<SQL || { echo "[trn-course] FATAL: MariaDB provisioning SQL failed" >&2; exit 1; }
CREATE USER IF NOT EXISTS '${SLURM_DB_USER}'@'localhost'  IDENTIFIED BY '${db_pw}';
CREATE USER IF NOT EXISTS '${SLURM_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${db_pw}';
SET PASSWORD FOR '${SLURM_DB_USER}'@'localhost'  = PASSWORD('${db_pw}');
SET PASSWORD FOR '${SLURM_DB_USER}'@'127.0.0.1' = PASSWORD('${db_pw}');
GRANT ALL PRIVILEGES ON *.* TO '${SLURM_DB_USER}'@'localhost'  WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${SLURM_DB_USER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
unset db_pw

echo "[trn-course] Slurm accounting DB user ready (user=${SLURM_DB_USER}@{localhost,127.0.0.1}, ALL on *.* WITH GRANT OPTION; slurmdbd will create the cluster-named DB)"
# f. Deliberately do NOT restart slurmdbd/slurmctld here: PC's chef
#    (config_slurm_accounting) starts slurmdbd itself, after OnNodeStart, and it
#    will connect to the DB we just created.
echo "[trn-course] head-node-db-setup done at $(date -u)"

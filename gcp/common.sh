# Shared settings of the gcp/ scripts. Sourced, not run.
#
# The project and region are read from gcp/terraform.tfvars, the one place they are written down.
# Credentials are your own Google account (gcloud auth login + application-default login),
# never a service account key.

tfvar() {
  sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\(.*\)\"/\1/p" gcp/terraform.tfvars
}

GCP_PROJECT="${GCP_PROJECT:-$(tfvar project_id)}"
GCP_REGION="${GCP_REGION:-$(tfvar region)}"
GCP_NAME="$(tfvar project_name)"
API_SERVICE="$GCP_NAME-api"
DB_INSTANCE="$GCP_NAME-db"
HOSTING_SITE="$GCP_PROJECT-app"
IMAGE_REPO="$GCP_REGION-docker.pkg.dev/$GCP_PROJECT/$GCP_NAME"

command -v gcloud >/dev/null || {
  echo "gcloud is not installed: https://cloud.google.com/sdk/docs/install" >&2
  exit 1
}

gc() {
  gcloud --project "$GCP_PROJECT" --quiet "$@"
}

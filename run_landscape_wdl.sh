#!/usr/bin/env bash
set -euo pipefail

show_usage() {
  cat <<EOF
Usage: $0 --input <input_json> [--branch <git_branch>]

Example:
  $0 --input celldega_inputs_visium.json --branch I_ST-addition
EOF
  exit 1
}

INPUT_JSON=""
BRANCH="main"  # Default branch if none provided

# Parse named arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      [[ $# -ge 2 ]] || { echo "Error: --input requires a value."; show_usage; }
      INPUT_JSON="$2"
      shift 2
      ;;
    --branch)
      [[ $# -ge 2 ]] || { echo "Error: --branch requires a value."; show_usage; }
      BRANCH="$2"
      shift 2
      ;;
    -h|--help)
      show_usage
      ;;
    *)
      echo "Error: Unknown argument: $1"
      show_usage
      ;;
  esac
done

INPUT_JSON="$(realpath "$INPUT_JSON")"

if [[ -z "$INPUT_JSON" ]]; then
  echo "Error: --input argument is required."
  show_usage
fi

if [[ ! -f "$INPUT_JSON" ]]; then
  echo "Error: Input JSON file '$INPUT_JSON' not found."
  exit 1
fi

# Check required dependencies
for cmd in jq git omics; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: Required command '$cmd' not found in PATH."
    exit 1
  fi
done

echo "Cleaning up previous Omics configurations..."
rm -rf ~/.omics ~/.aws/cli/omics || true

# Extract bucket path from JSON
output_bucket_path=$(jq -r '."LandscapeFiles.bucket_path_landscape_files"' "$INPUT_JSON")

if [[ -z "$output_bucket_path" || "$output_bucket_path" == "null" ]]; then
  echo "Error: Could not read LandscapeFiles.bucket_path_landscape_files from $INPUT_JSON."
  exit 1
fi

echo "Output bucket path: $output_bucket_path"

# Create temp working directory
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cd "$WORKDIR"
echo "Cloning workflow repository..."
git clone --depth 1 --branch "$BRANCH" https://github.com/broadinstitute/stp_celldega_landscape_files.git

cd stp_celldega_landscape_files
echo "Using branch: $BRANCH"

# Verify checkout
current_branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$current_branch" != "$BRANCH" ]]; then
  echo "Error: Failed to switch to branch '$BRANCH'. Currently on '$current_branch'."
  exit 1
fi

echo "Running Omics workflow from branch '$BRANCH'..."
omics LandscapeFiles.wdl \
  --input "$INPUT_JSON" \
  --output-uri "${output_bucket_path%/}/workflow_logs/"

echo "Workflow submitted successfully."

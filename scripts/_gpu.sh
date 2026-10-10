# Per-card settings, shared by create-pod.sh, verify-pod.sh and pre-check.sh. Sourced, not run.
#
# A setting can be given per GPU card: NAME_<CARD> beats NAME, which beats the default. <CARD> is the card's id in
# capital letters with every run of characters other than letters and digits turned into one "_":
#   "NVIDIA H200" -> NVIDIA_H200,  "NVIDIA B300 SXM6 AC" -> NVIDIA_B300_SXM6_AC
# so MAX_NUM_SEQS_NVIDIA_B200=12 in .env sets MAX_NUM_SEQS for the B200 only. Meant for the settings that depend on the
# card's memory: MAX_NUM_SEQS, MAX_MODEL_LEN, PLE_MMAP, GPU_MEMORY_UTILIZATION. The per-card variables have to be in .env
# (the Makefile forwards only fixed variable names when there is no .env file).

# gpu_key CARD: prints the suffix.
gpu_key() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9][^A-Z0-9]*/_/g; s/^_//; s/_$//'
}

# gpu_setting NAME CARD [DEFAULT]: prints the value for the card (empty string counts as not set).
gpu_setting() {
  local name="$1" card="$2" default="${3:-}" specific v
  specific="${name}_$(gpu_key "$card")"
  v="${!specific:-}"
  [ -n "$v" ] || v="${!name:-}"
  printf '%s' "${v:-$default}"
}

# gpu_setting_source NAME CARD: prints the name of the variable that gpu_setting would read (or nothing if none is set).
gpu_setting_source() {
  local name="$1" card="$2" specific
  specific="${name}_$(gpu_key "$card")"
  if [ -n "${!specific:-}" ]; then printf '%s' "$specific"; elif [ -n "${!name:-}" ]; then printf '%s' "$name"; fi
}

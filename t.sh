probe() (
  _probe_cleanup() { echo "CLEANUP"; }
  trap "_probe_cleanup" EXIT
  trap "_probe_cleanup; printf \"failed\n\"; exit 0" TERM
  kill -TERM 139089          # signal ourselves, no child in the way
  echo "BODY CONTINUED"
)
probe

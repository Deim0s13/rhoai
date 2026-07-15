#!/usr/bin/env bash
# Tear down UC02 completely. The rebuild test: teardown, bootstrap, seed, and
# the stack should return with no manual intervention. If it does not, the gap
# is a repo bug, not a thing to remember.
set -euo pipefail
NS=complaint-intelligence

echo "This deletes the $NS namespace and everything in it."
read -p "Type the namespace name to confirm: " confirm
[ "$confirm" = "$NS" ] || { echo "Aborted."; exit 1; }

oc delete namespace "$NS" --wait=true
echo "Gone. Rebuild with: ./scripts/bootstrap.sh && ansible-playbook ansible/site.yml"

#!/bin/bash
# Carica le variabili da .env e lancia l'orchestratore completo (site.yml).
# Uso: ./site.sh [argomenti extra per ansible-playbook]  es: ./site.sh --check
set -euo pipefail

if [ ! -f .env ]; then
    echo "Errore: file .env non trovato!" >&2
    exit 1
fi

# Carica il .env nell'ambiente, cosi' i lookup('env', ...) lo vedono.
set -a
# shellcheck source=/dev/null
source .env
set +a

# inventory, chiave e vault_password_file arrivano gia' da ansible.cfg/inventory.
ansible-playbook site.yml "$@"

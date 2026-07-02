#!/bin/bash
#
# Carica le variabili da .env e lancia il playbook dei servizi.
# Uso: ./avvio_servizi.sh [argomenti extra per ansible-playbook]
#   es: ./avvio_servizi.sh --tags db
#       ./avvio_servizi.sh --check

# Interrompi lo script al primo errore, su variabili non definite, e
# se un comando in una pipe fallisce. Rende i problemi visibili subito.
set -euo pipefail

# 1. Verifica che il file .env esista
if [ ! -f .env ]; then
    echo "Errore: file .env non trovato!" >&2
    exit 1
fi

# 2. Carica le variabili dal .env nell'ambiente.
#    'set -a' esporta automaticamente ogni variabile definita da qui in poi;
#    'source .env' le legge (gestendo correttamente spazi e virgolette);
#    'set +a' disattiva l'export automatico.
set -a
# shellcheck source=/dev/null
source .env
set +a

# 3. Verifica che la chiave privata sia stata definita nel .env
if [ -z "${PRIVATE_KEY_PATH:-}" ]; then
    echo "Errore: PRIVATE_KEY_PATH non definita nel .env!" >&2
    exit 1
fi

# 4. Lancio di Ansible.
#    "$@" passa allo script qualsiasi argomento extra (tag, --check, ecc.)
#    direttamente ad ansible-playbook.
ansible-playbook avvio_servizi.yml "$@"

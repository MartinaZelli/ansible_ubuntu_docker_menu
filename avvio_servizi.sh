#!/bin/bash

# 1. Verifica che i file necessari esistano
if [ ! -f .env ]; then
    echo "Errore: file .env non trovato!"
    exit 1
fi

# 2. Esporta le variabili dal file .env
export $(grep -v '^#' .env | xargs)

# 3. Lancio di Ansible
# L'aggiunta di "$@" permette di passare qualsiasi argomento (inclusi i tag)
# passati allo script direttamente al comando ansible-playbook
ansible-playbook -i inventory.yml \
  --private-key "$PRIVATE_KEY_PATH" \
  avvio_servizi.yml "$@"

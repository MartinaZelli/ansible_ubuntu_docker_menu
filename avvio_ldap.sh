#!/bin/bash

# 1. Verifica che i file necessari esistano
if [ ! -f .env ]; then
    echo "Errore: file .env non trovato!"
    exit 1
fi

# 2. Esporta le variabili dal file .env
# Usiamo -a per esportare automaticamente le variabili caricate
set -a
source .env
set +a

# 3. Lancio di Ansible puntando al playbook di ldap
echo "avvio installazione LDAP..."
ansible-playbook -i inventory.yml \
  --private-key "$PRIVATE_KEY_PATH" \
  ldap.yml "$@"

#!/bin/bash

# 1. Verifica che i file necessari esistano
if [ ! -f .env ]; then
    echo "Errore: file .env non trovato!"
    exit 1
fi

if [ ! -f .vault_pass ]; then
    echo "Errore: file .vault_pass non trovato!"
    exit 1
fi

# 2. Esporta le variabili dal file .env
export $(grep -v '^#' .env | xargs)

# 3. Lancio di Ansible
# Aggiungiamo --vault-password-file=.vault_pass per automatizzare la decrittazione
ansible-playbook -i inventory.yml \
  --private-key "$PRIVATE_KEY_PATH" \
  --vault-password-file=.vault_pass \
  avvio_servizi.yml

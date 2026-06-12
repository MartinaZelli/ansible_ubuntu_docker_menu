# Progetto: Infrastruttura Distribuita FastAPI & MySQL + Identità Centralizzata LDAP

Automazione Ansible per il deployment di un'architettura scalabile (database MySQL,
nodi applicativi FastAPI, load balancer HAProxy) su Ubuntu 24.04 LTS, **estesa** con
un layer di **identità centralizzata basato su LDAP** (OpenLDAP + SSSD) che gestisce
autenticazione e autorizzazione degli utenti sulle macchine del parco.

Il repository contiene quindi due workflow complementari:

| Workflow | Scopo | Avvio | Segreti |
|----------|-------|-------|---------|
| **Application stack** | Deploy di DB, app FastAPI, HAProxy | `./avvio_servizi.sh` | `.env` |
| **Identità LDAP** | Server LDAP + client SSSD | `./avvio_ldap.sh` | **Ansible Vault** |

> Il provisioning delle VM (libvirt/KVM) è gestito da un repository Terraform separato
> (`terraform_exercise`); questo repository si occupa solo della **configurazione**.

---

## Prerequisiti

Sulla macchina di controllo:

* **Ansible** >= 2.14 e **Python 3.x**.
* **Collezioni Ansible**:
  ```bash
  ansible-galaxy collection install community.general   # moduli ldap_entry/ldap_attrs/debconf
  ansible-galaxy collection install community.crypto     # generazione certificati TLS (layer LDAP)
  ```
* **Accesso SSH** (chiave Ed25519) verso tutti i target. Il percorso della chiave
  privata va indicato in `.env` (`PRIVATE_KEY_PATH`).
* **Per il layer LDAP**: un file `.vault_pass` con la password del Vault (vedi sotto).

---

## Architettura

### A. Application stack (stack "menu")

Approccio a micro-servizi isolati:
* **Database**: container MySQL 8.0.
* **Application Tier**: nodi FastAPI in un gruppo di scaling (`app_servers`).
* **Load Balancing**: HAProxy (nativo) che bilancia il traffico verso le app e
  monitora i backend con health check.

Applicazione: `https://github.com/MartinaZelli/menu_v2.0.git`

### B. Layer di identità LDAP

* **`ldap_server`** (host `ldap`): server OpenLDAP (`slapd`) con base DN
  `dc=lab,dc=home`, utenti (`inetOrgPerson` + `posixAccount`), gruppi (`posixGroup`)
  e **TLS** (CA privata, StartTLS sulla 389, LDAPS sulla 636).
* **`ldap_client`** (host `lb`): configurazione **SSSD** che delega a LDAP la
  risoluzione delle identità (NSS) e l'autenticazione (PAM) sul canale cifrato, con
  autorizzazione per gruppo (solo i membri di `devops` possono accedere).

Flusso di accesso: un utente che esiste **solo** in LDAP fa login su una macchina
che non lo ha in `/etc/passwd`; SSSD interroga il server LDAP, verifica le
credenziali (bind) e applica la policy di accesso.

---

## Configurazione

### 1. File `.env` (stack applicativo)

Crea `.env` nella root basandoti su `.env.example`. Contiene le configurazioni
**non gestite dal Vault**: credenziali DB, IP degli host, porte, token Git e il
percorso della chiave SSH (`PRIVATE_KEY_PATH`). È **gitignorato**.

> Nota: i segreti del layer LDAP **non** stanno più nel `.env` — sono migrati nel
> Vault (vedi punto 2).

### 2. Ansible Vault (segreti del layer LDAP)

I segreti LDAP (password admin della directory, hash delle password utente) sono
cifrati con Ansible Vault e versionati nel repository in forma cifrata.

**a) Password del Vault.** Crea il file `.vault_pass` (gitignorato) con una password
robusta, e indicalo in `ansible.cfg`:

```bash
openssl rand -base64 32 > .vault_pass
chmod 600 .vault_pass
```

```ini
# ansible.cfg  ->  sezione [defaults]
vault_password_file = .vault_pass
```

**b) Struttura vars/vault.** I segreti vivono in `group_vars/ldap_servers/`, diviso
secondo la best practice in due file:

```
group_vars/ldap_servers/
├── vars.yml     # in chiaro: nomi leggibili che puntano ai segreti del vault
└── vault.yml    # CIFRATO: i valori reali, con prefisso vault_
```

`vault.yml` (cifrato) contiene:
```yaml
vault_ldap_server_admin_password: "..."               # password admin LDAP (in chiaro)
vault_ldap_server_user_mzelli_password: "{SSHA}..."   # hash SSHA
vault_ldap_server_user_esterno_password: "{SSHA}..."  # hash SSHA
```

`vars.yml` (in chiaro) fa da strato di indirezione:
```yaml
ldap_server_admin_password: "{{ vault_ldap_server_admin_password }}"
```

Gli hash delle password utente vengono referenziati per nome dai `defaults` del
ruolo (`password_var: "vault_..."`) e risolti con `lookup('vars', ...)`.

**c) Gestione del Vault** (comandi utili):
```bash
ansible-vault view group_vars/ldap_servers/vault.yml    # visualizza in chiaro
ansible-vault edit group_vars/ldap_servers/vault.yml    # modifica (richiede $EDITOR)
ansible-vault rekey group_vars/ldap_servers/vault.yml   # cambia la password del vault
```

> **Su Arch:** se `ansible-vault edit/create` lamenta `vi: File o directory non
> esistente`, imposta l'editor: `EDITOR=vim ansible-vault edit ...` (o aggiungi
> `export EDITOR=vim` al `~/.bashrc`).

**d) Hash delle password utente.** In LDAP le password utente si memorizzano
hashate. Genera l'hash sulla VM server (dove esiste `slappasswd`) e incollalo nel
vault:
```bash
ssh -i ~/.ssh/id_archvm ubuntu@192.168.1.76 'slappasswd -h {SSHA}'
```

---

## Procedure di avvio

Rendi eseguibili gli script una volta:
`chmod +x avvio_servizi.sh avvio_ldap.sh cleanup_servizi.sh`

### Stack applicativo
```bash
./avvio_servizi.sh                 # deploy completo (DB + app + LB)
./avvio_servizi.sh -t db           # solo database
./avvio_servizi.sh -t app          # solo applicazione
./avvio_servizi.sh -t lb           # solo load balancer
./avvio_servizi.sh --check         # dry-run (nessuna modifica applicata)
```

### Layer LDAP
```bash
./avvio_ldap.sh                    # configura server LDAP + client SSSD
```
Lo script esporta le variabili del `.env` e lancia il playbook `ldap.yml`. La
password del Vault viene letta automaticamente da `.vault_pass` (via `ansible.cfg`),
quindi **non** serve `--ask-vault-pass`.

### Cleanup dello stack applicativo
```bash
./cleanup_servizi.sh               # rimozione sicura e idempotente delle risorse
```

---

## Il layer LDAP in dettaglio

### Ruolo `ldap_server`

| File | Responsabilità |
|------|----------------|
| `tasks/install.yml` | Installazione non interattiva di `slapd` via **preseed debconf** + dipendenze (`python3-ldap`, `python3-cryptography`). |
| `tasks/structure.yml` | Crea `ou=people`/`ou=groups`, utenti (`inetOrgPerson`+`posixAccount`), gruppi (`posixGroup`). Pattern **esistenza** (`ldap_entry`) **+ attributi** (`ldap_attrs state: exact`). |
| `tasks/tls.yml` | Genera CA privata e certificato server (`community.crypto`), configura il TLS in `cn=config`, abilita LDAPS. |
| `handlers/main.yml` | Riavvio di `slapd`. |

### Ruolo `ldap_client`

| File | Responsabilità |
|------|----------------|
| `tasks/main.yml` | Installa SSSD, **recupera la CA dal server** (`slurp` + `delegate_to` -> `copy`), scrive `sssd.conf`, abilita PAM/`mkhomedir`. |
| `templates/sssd.conf.j2` | Config SSSD: `id_provider`/`auth_provider = ldap`, `ldaps://`, `ldap_tls_cacert`, e l'autorizzazione `access_provider = simple` + `simple_allow_groups`. |
| `handlers/main.yml` | Riavvio di `sssd`. |

---

## Struttura del progetto

```
.
├── ansible.cfg                      # config globale (include vault_password_file)
├── .env / .env.example              # variabili dello stack applicativo (gitignorato)
├── .vault_pass                      # password del Vault (gitignorato)
├── inventory.yml                    # host e gruppi
│
├── avvio_servizi.sh / .yml          # workflow: deploy stack applicativo
├── cleanup_servizi.sh / .yml        # workflow: pulizia stack applicativo
├── avvio_ldap.sh                    # workflow: layer LDAP
├── ldap.yml                         # playbook LDAP (server + client)
│
├── group_vars
│   ├── all.yml                      # variabili globali stack applicativo
│   └── ldap_servers
│       ├── vars.yml                 # riferimenti in chiaro ai segreti del vault
│       └── vault.yml                # segreti LDAP CIFRATI
│
├── docs/                            # appunti / runbook di studio
│
└── roles
    ├── costruzione_progetto/        # stack applicativo (DB, app, HAProxy)
    ├── project_cleanup/             # rimozione idempotente delle risorse
    ├── ldap_server/                 # server OpenLDAP (install, struttura, TLS)
    │   ├── defaults/main.yml
    │   ├── tasks/{main,install,structure,tls}.yml
    │   └── handlers/main.yml
    └── ldap_client/                 # client SSSD
        ├── defaults/main.yml
        ├── tasks/main.yml
        ├── templates/sssd.conf.j2
        └── handlers/main.yml
```

---

## Modulo di Cleanup (`project_cleanup`)

Procedura dedicata alla rimozione dello stack applicativo, idempotente e sicura:
* **Risorse**: elimina container Docker, volumi dati e directory di progetto.
* **HAProxy**: rimuove chirurgicamente i backend dai file di configurazione usando i
  marker, senza compromettere il resto.
* **Firewall (UFW)**: ripulisce le regole create in fase di avvio.
* **Resilienza**: verifiche preventive (`stat`) per ogni risorsa; se già rimossa, il
  task viene saltato senza errori.

---

## Comandi utili (debug, verifica, manutenzione)

**Inventario e connettività**
```bash
ansible-inventory -i inventory.yml --graph        # albero gruppi/host
ansible -i inventory.yml ldap -m ping             # raggiungibilità (separa infra da config)
```

**Debug variabili**
```bash
ansible -i inventory.yml -m debug -a "var=db_conn.host" db
```

**Verifica del layer LDAP** (server `ldap` = 192.168.1.76, client `lb` = 192.168.1.75)
```bash
# server: porte in ascolto e bind cifrato
ssh -i ~/.ssh/id_archvm ubuntu@192.168.1.76 'ss -tlnp | grep -E "389|636"'
ssh -i ~/.ssh/id_archvm ubuntu@192.168.1.76 \
  'ldapwhoami -x -H ldaps://ldap.lab.home -D "uid=mzelli,ou=people,dc=lab,dc=home" -W'

# client: risoluzione identità + login + autorizzazione
ssh -i ~/.ssh/id_archvm ubuntu@192.168.1.75 'getent passwd mzelli'
ssh -i ~/.ssh/id_archvm ubuntu@192.168.1.75 'id mzelli'
# su - mzelli   -> consentito (membro di devops)
# su - esterno  -> Permission denied (non in devops)
```

**Cache SSSD** (dopo modifiche lato server, sul client)
```bash
ssh -i ~/.ssh/id_archvm ubuntu@192.168.1.75 'sudo sss_cache -E'
```

**Sicurezza del Vault** (prima di committare)
```bash
head -1 group_vars/ldap_servers/vault.yml    # deve iniziare con $ANSIBLE_VAULT;1.1;AES256
git status                                     # .vault_pass NON deve comparire
```

---

## Note operative e hardening futuri

* **Provisioning VM**: gestito dal repo Terraform separato. Per testare i ruoli "da
  zero" si ricrea il **disco** della VM (non solo il dominio):
  `tofu apply -replace='libvirt_volume.vm_disk["ldap"]' -replace='libvirt_domain.vm["ldap"]'`.
* **`ssh_pwauth: false`** sulle VM: il login LDAP via SSH con password è disabilitato
  dal cloud-init; per i test si usa `su - <utente>`.
* **Hardening da valutare**: password del Vault recuperata da un password manager
  (script eseguibile come `vault_password_file`); passphrase sulla chiave della CA;
  rimozione di `StrictHostKeyChecking=no` fuori dal lab.

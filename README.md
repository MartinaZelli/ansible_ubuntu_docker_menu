# Infrastruttura: stack applicativo dietro un bastion host con identità Active Directory

Automazione Ansible per il deployment di un'architettura a più nodi (MySQL, app
FastAPI in Docker, load balancer HAProxy) su Ubuntu 24.04, protetta da un **bastion
host** e integrata in un dominio **Active Directory** (Samba AD-DC): le persone
accedono con la loro identità di dominio, i nodi interni sono raggiungibili solo
attraverso il bastion, e il single sign-on Kerberos permette di saltare dal bastion
ai nodi senza ridigitare credenziali.

> Il provisioning delle VM (libvirt/KVM) è gestito da un repository Terraform separato
> (`terraform_exercise`). Questo repository si occupa solo della **configurazione**.

## I tre pilastri

| Pilastro | Cosa fa | Playbook |
|----------|---------|----------|
| **Identità & accesso (AD)** | Join al dominio, login AD, SSO Kerberos, bastion | `ad.yml` |
| **Sicurezza di rete** | Lockdown firewall: i nodi interni accettano SSH solo dal bastion | `firewall.yml` |
| **Stack applicativo** | Deploy di MySQL, app FastAPI (Docker), HAProxy | `avvio_servizi.yml` (via `avvio_servizi.sh`) |

> Esiste anche un **layer LDAP** (OpenLDAP + SSSD) come ramo di studio, ora **congelato**
> (la VM è parcheggiata). I ruoli `ldap_server`/`ldap_client` restano nel repo per un
> eventuale ripristino. Vedi `docs/` per i dettagli.

---

## Architettura

### Il modello bastion

```
   IL TUO PC                  BASTION (.78)              NODI INTERNI
  (utente AD)  --login AD-->  [ porta unica ]  --SSO-->  lb  (.75) HAProxy
                              identita mzelli            app (.72) FastAPI/Docker
                                                         db  (.73) MySQL
```

- **Il bastion e l'unica porta d'ingresso**: i nodi interni (`lb`, `app`, `db`)
  accettano SSH **solo dal bastion** (firewall `ufw`, default deny).
- **Identita per persona via AD**: si fa login come `mzelli@ad.lab.home` (account di
  dominio, gruppo `devops`), non con una chiave anonima condivisa.
- **Single sign-on Kerberos**: dal bastion si salta ai nodi (`ssh menu-app.ad.lab.home`)
  senza credenziali — il ticket Kerberos viaggia con l'utente.

> Nel lab la rete e piatta: l'isolamento lo fa il **firewall su ogni host**, non la
> segmentazione di rete. In produzione si aggiungerebbe subnet/VLAN come seconda barriera.

### Lo stack applicativo

Micro-servizi isolati, ciascuno su un nodo dedicato:
- **`db`**: MySQL in container Docker, espone 3306 **solo** ai nodi app + lb.
- **`app`** (+ `app2` quando attiva): app FastAPI in Docker, espone la porta app
  **solo** al load balancer.
- **`lb`**: HAProxy nativo, bilancia il traffico HTTP verso i nodi app; pannello stats.

I servizi si parlano tra loro **dentro** la cornice di sicurezza: il firewall apre le
porte di servizio con privilegio minimo (solo le sorgenti che servono), pur tenendo i
nodi murati all'accesso SSH diretto.

---

## I gruppi dell'inventory

| Gruppo | Membri | Ruolo |
|--------|--------|-------|
| `ad_clients` | bastion, lb, app, db | nodi uniti al dominio AD (`ad_client`) |
| `internal` | lb, app, db | nodi dietro il bastion (firewall + ProxyJump) |
| `app_servers` | app (, app2) | nodi applicativi |
| `db_servers` | db | nodi database |
| `lb_servers` | lb | load balancer |

> `app2` e commentata nell'inventory (parcheggiata per risparmiare RAM). Si riattiva
> togliendo il commento qui e in `terraform`, poi rilanciando i playbook.

---

## Prerequisiti

Sulla macchina di controllo:
- **Ansible** >= 2.14 e **Python 3.x**.
- **Collezioni Ansible**:
  ```bash
  ansible-galaxy collection install community.general   # ufw, debconf, blockinfile
  ansible-galaxy collection install community.docker    # container e compose
  ```
- **Accesso SSH** (chiave Ed25519, `~/.ssh/id_archvm`) verso il bastion e — via
  ProxyJump — verso i nodi interni.
- **`~/.ssh/config`** configurato per il salto via bastion (vedi sotto).
- **`.vault_pass`** con la password del Vault (per i segreti cifrati).

### Il `~/.ssh/config` (accesso via bastion)

Perche Ansible e l'uso a mano raggiungano i nodi interni attraverso il bastion senza
dipendere dall'ssh-agent, ogni nodo ha un blocco con **alias + IP** e `ProxyJump`:

```ssh-config
Host bastion 192.168.1.78
    HostName 192.168.1.78
    User ubuntu
    IdentityFile ~/.ssh/id_archvm

Host menu-lb 192.168.1.75
    HostName 192.168.1.75
    User ubuntu
    IdentityFile ~/.ssh/id_archvm
    ProxyJump bastion
# ... blocchi analoghi per menu-app (.72) e menu-db (.73) ...

# Login sul bastion come utente di dominio (per il flusso quotidiano)
Host bastion-ad
    HostName 192.168.1.78
    User mzelli@ad.lab.home
    PreferredAuthentications password
    PubkeyAuthentication no
    GSSAPIDelegateCredentials yes
```

L'IP nel blocco `Host` e essenziale: Ansible si connette per IP, e cosi eredita il
ProxyJump. Permessi: `chmod 600 ~/.ssh/config`.

---

## Configurazione

### File `.env` (stack applicativo)

Lo stack legge la configurazione da variabili d'ambiente, caricate da `.env` (NON
versionato — contiene segreti). Parti da `.env.example`:

```bash
cp .env.example .env    # poi compila i valori reali
```

Variabili chiave: `GIT_REPO`, `GIT_VERSION` (branch dell'app), `DB_HOST` (IP del nodo
db), `LB_FRONTEND_PORT`, `LB_STATS_PORT`, `PRIVATE_KEY_PATH`. Le password e il token git
stanno nel **Vault**, non nel `.env`.

### Ansible Vault (segreti)

I segreti cifrati vivono in `group_vars/*/vault.yml`:
- `group_vars/all/vault.yml`: token git, password DB.
- `group_vars/ad_clients/vault.yml`: password di join al dominio AD.

```bash
ansible-vault edit group_vars/all/vault.yml          # modificare
# .vault_pass + ansible.cfg (vault_password_file) per non digitare la password ogni volta
```

---

## Procedure di avvio

L'ordine conta: **prima identita e firewall, poi lo stack** (cosi i nodi sono gia
integrati e protetti quando l'app gira).

### 1. Integrazione AD + SSO

```bash
ansible-playbook -i inventory.yml ad.yml
```
Unisce i nodi al dominio, configura ID mapping, login AD (solo bastion), GSSAPI/SSO, e
la config client del bastion.

### 2. Lockdown firewall (due tempi, anti-lockout)

```bash
# Tempo 1: SSH da bastion + tuo PC (paracadute). Verifica l'accesso.
ansible-playbook -i inventory.yml firewall.yml
# Tempo 2: rimuove il paracadute, resta solo il bastion.
ansible-playbook -i inventory.yml firewall.yml -e firewall_lockdown=true
```

### 3. Stack applicativo

```bash
./avvio_servizi.sh              # carica .env (set -a/source) e lancia avvio_servizi.yml
./avvio_servizi.sh --tags lb    # solo il load balancer
```

### Cleanup dello stack

```bash
./cleanup_servizi.sh            # rimuove container/config dello stack applicativo
```

---

## Flusso quotidiano (accesso)

```bash
ssh bastion-ad                  # login sul bastion come mzelli (password AD)
ssh menu-app.ad.lab.home        # salto SSO al nodo, senza credenziali (ticket delegato)
```

Stats di HAProxy: `http://192.168.1.75:<LB_STATS_PORT>/stats` (es. `:8080/stats`).

---

## I ruoli

| Ruolo | Responsabilita |
|-------|----------------|
| `ad_client` | join AD, ID mapping, login AD per `devops`, GSSAPI + localauth (SSO) |
| `bastion` | config client del bastion per il salto SSO ai nodi `*.ad.lab.home` |
| `firewall` | cornice di sicurezza: default deny + SSH solo dal bastion (due tempi) |
| `costruzione_progetto` | stack app: Docker, MySQL, deploy FastAPI, HAProxy (+ porte di servizio) |
| `project_cleanup` | rimozione dello stack applicativo |
| `ldap_server` / `ldap_client` | ramo LDAP, **congelato** (ripristino futuro) |

### Nota di design: cornice vs servizi (firewall)

Il firewall ha **una sola fonte di verita per tipo di regola**:
- Il ruolo `firewall` possiede la **cornice**: SSH-solo-dal-bastion, default deny, enable.
- Il ruolo `costruzione_progetto` possiede le **porte di servizio**: 3306 (MySQL dai nodi
  app), porta app (dal solo lb), 80/stats (HAProxy).

Si applica `firewall` *prima*, poi lo stack aggiunge i suoi fori. Nessuna sovrapposizione.

### Nota di design: HAProxy idempotente

La config di HAProxy e generata da **un unico template** (`haproxy.cfg.j2`: global,
defaults, frontend, backend dinamici sui server). Il task usa `validate: haproxy -c`:
se la config e invalida, non viene applicata e HAProxy non viene riavviato con un file
rotto. Idempotente per costruzione (nessun `force_config` da passare a mano).

---

## Struttura del progetto

```
.
├── ad.yml                  # playbook: integrazione AD + SSO
├── firewall.yml            # playbook: lockdown firewall
├── avvio_servizi.yml       # playbook: stack applicativo (hosts: internal)
├── avvio_servizi.sh        # wrapper: carica .env e lancia
├── cleanup_servizi.yml     # playbook: cleanup stack
├── inventory.yml           # host e gruppi (IP = fonte unica)
├── ansible.cfg             # config (inventory, vault_password_file)
├── group_vars/
│   ├── all/                # vars.yml + vault.yml (segreti app)
│   └── ad_clients/         # vault.yml (password join AD)
├── host_vars/
│   ├── lb.yml, app.yml, db.yml   # login AD disabilitato (nodi-servizio)
├── roles/
│   ├── ad_client/  bastion/  firewall/
│   ├── costruzione_progetto/     # templates/haproxy.cfg.j2, ecc.
│   └── ldap_server/ ldap_client/ project_cleanup/
└── docs/                   # runbook (bastion, AD, LDAP)
```

---

## Comandi utili (debug, verifica)

```bash
# Identita AD e SSO
ansible -i inventory.yml app:db -m command -a "id mzelli@ad.lab.home" --become
ssh bastion-ad   # poi: ssh menu-db.ad.lab.home 'whoami; klist'

# Firewall: regole reali (vista ufw)
ssh 192.168.1.75 'sudo ufw status verbose'

# Diretto VERO bloccato? (deve andare in timeout)
ssh -F /dev/null -i ~/.ssh/id_archvm -o ConnectTimeout=10 ubuntu@192.168.1.75 'echo test'

# HAProxy: config valida + porte in ascolto
ssh 192.168.1.75 'sudo haproxy -c -f /etc/haproxy/haproxy.cfg; sudo ss -tlnp | grep -E ":80|:8080"'
```

---

## Note operative e hardening futuri

- **`StrictHostKeyChecking=no`** e comodo nel lab ma andrebbe rimosso in produzione
  (gestendo le host key con `accept-new` o known_hosts versionati).
- **IP admin DHCP**: la regola-paracadute del firewall usa l'IP del PC (`.23`), che e
  dinamico — potrebbe non corrispondere se cambia.
- **Codice morto da rimuovere**: i vecchi template HAProxy (`haproxy_base.cfg.j2`,
  `backend_app.cfg.j2`, `backend_db.cfg.j2`) e `force_config` non sono piu usati.
- **`avvio_servizi.sh`**: carica `.env` con `set -a; source` (robusto su spazi/virgolette).

---

*Lab a scopo di studio, rete locale, software open-source.*

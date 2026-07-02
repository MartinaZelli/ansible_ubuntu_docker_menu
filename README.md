# Infrastruttura: stack applicativo dietro un bastion host con identità Active Directory

Automazione Ansible per il deployment di un'architettura a più nodi (MySQL, app
FastAPI in Docker, load balancer HAProxy) su Ubuntu 24.04, protetta da un **bastion
host** e integrata in un dominio **Active Directory** (Samba AD-DC): le persone
accedono con la loro identità di dominio, i nodi interni sono raggiungibili solo
attraverso il bastion, e il single sign-on Kerberos permette di saltare dal bastion
ai nodi senza ridigitare credenziali.

> Il provisioning delle VM (libvirt/KVM) è gestito da un repository Terraform separato
> (`terraform_exercise`). Questo repository si occupa della **configurazione** — con
> l'eccezione del ruolo `domain_controller`, che sa ricostruire il DC da zero (vedi sotto).

## I quattro pilastri

| Pilastro | Cosa fa | Playbook |
|----------|---------|----------|
| **Preparazione di base** | Rete IPv4-only (fix RA), prerequisito per risolvere il dominio | `base.yml` |
| **Identità & accesso (AD)** | Domain Controller, join al dominio, login AD, SSO Kerberos, bastion | `dc.yml`, `ad.yml` |
| **Sicurezza di rete** | Firewall: i nodi (e il DC) accettano SSH solo dal bastion; porte AD solo alla LAN | `firewall.yml` |
| **Stack applicativo** | Deploy di MySQL, app FastAPI (Docker), HAProxy | `avvio_servizi.yml` (via `avvio_servizi.sh`) |

> Un **orchestratore** `site.yml` (via `site.sh`) esegue in ordine base → identità →
> stack → firewall con un solo comando. Vedi *Procedure di avvio*.

> Il **layer LDAP** (OpenLDAP + SSSD), ramo di studio, è stato spostato sul branch
> dedicato `feature/ldap` e **rimosso da questo branch**. Restano solo alcuni documenti
> di riferimento in `docs/`.

---

## Architettura

### Il modello bastion

```
   IL TUO PC                  BASTION (.78)              NODI INTERNI
  (utente AD)  --login AD-->  [ porta unica ]  --SSO-->  lb  (.75) HAProxy
                              identita mzelli            app (.72) FastAPI/Docker
                                                         db  (.73) MySQL

                              DC / dc1 (.77)  <-- DNS + Kerberos di tutto il dominio
```

- **Il bastion è l'unica porta d'ingresso**: i nodi interni (`lb`, `app`, `db`) e il
  **DC** accettano SSH **solo dal bastion** (firewall `ufw`, default deny).
- **Identità per persona via AD**: si fa login come `mzelli@ad.lab.home` (account di
  dominio, gruppo `devops`), non con una chiave anonima condivisa.
- **Single sign-on Kerberos**: dal bastion si salta ai nodi (`ssh menu-app.ad.lab.home`)
  senza credenziali — il ticket Kerberos viaggia con l'utente.
- **Il DC serve il dominio**: `dc1` (.77) è DNS e KDC Kerberos. Ogni nodo membro lo usa
  per risolvere `*.ad.lab.home` e per autenticare.

> Nel lab la rete è piatta: l'isolamento lo fa il **firewall su ogni host**, non la
> segmentazione di rete. In produzione si aggiungerebbe subnet/VLAN come seconda barriera.

### Le macchine (chiave Terraform → hostname → IP)

| Ruolo | hostname | IP | Note |
|-------|----------|----|------|
| Domain Controller | `dc1` | .77 | Samba AD-DC, DNS + Kerberos |
| Bastion | `bastion` | .78 | porta d'ingresso unica |
| Load balancer | `menu-lb` | .75 | HAProxy |
| App | `menu-app` | .72 | FastAPI/Docker |
| Database | `menu-db` | .73 | MySQL/Docker |
| App #2 | `menu-app-2` | .74 | **parcheggiata** (RAM) |
| LDAP | `ldap` | .76 | **parcheggiata** (ramo congelato) |

### Lo stack applicativo

Micro-servizi isolati, ciascuno su un nodo dedicato:
- **`db`**: MySQL in container Docker, espone 3306 **solo** ai nodi app + lb.
- **`app`** (+ `app2` quando attiva): app FastAPI in Docker, espone la porta app
  **solo** al load balancer.
- **`lb`**: HAProxy nativo, bilancia il traffico HTTP verso i nodi app; pannello stats.

I servizi si parlano tra loro **dentro** la cornice di sicurezza: le porte di servizio
sono aperte con privilegio minimo (solo le sorgenti che servono), pur tenendo i nodi
murati all'accesso SSH diretto.

---

## I gruppi dell'inventory

| Gruppo | Membri | Ruolo |
|--------|--------|-------|
| `ad_clients` | bastion, lb, app, db | nodi uniti al dominio AD (`ad_client`, `base_system`) |
| `domain_controllers` | dc1 | il Domain Controller (DNS/Kerberos) |
| `internal` | lb, app, db | nodi dietro il bastion (firewall + ProxyJump) |
| `menu_stack` | lb, app, db | lo stack applicativo (deploy + cleanup) |
| `app_servers` | app (, app2) | nodi applicativi |
| `db_servers` | db | nodi database |
| `lb_servers` | lb | load balancer |

> `app2` è commentata nell'inventory (parcheggiata per risparmiare RAM). Si riattiva
> togliendo il commento qui e in `terraform`, poi rilanciando i playbook.

### Accesso di Ansible via bastion (ProxyJump nell'inventory)

I gruppi `internal` e `domain_controllers` impostano nell'inventory:

```yaml
ansible_ssh_common_args: '-o StrictHostKeyChecking=accept-new -o ProxyJump=ubuntu@192.168.1.78'
```

Così **Ansible raggiunge quei nodi saltando dal bastion**, esattamente come l'accesso
interattivo. È il prerequisito per poter chiudere l'SSH diretto: dopo il lockdown, solo
il bastion può entrare, e Ansible sopravvive perché salta da lì.

> Nota di precedenza: una variabile definita a livello di gruppo **sostituisce** (non
> fonde) quella di `all`, per questo la stringa include *anche* `StrictHostKeyChecking`.
> Poiché `lb/app/db` appartengono a `internal`, quel ProxyJump vale per loro in *ogni*
> playbook (anche `avvio_servizi.yml`), non solo nel firewall.

---

## Prerequisiti

### Macchina di controllo (il tuo PC)

- **Ansible** ≥ 2.14 e **Python 3.x**.
- **Collezioni Ansible**:
  ```bash
  ansible-galaxy collection install community.general   # ufw, debconf, blockinfile
  ansible-galaxy collection install community.docker    # container e compose
  ```
- **Accesso SSH** (chiave Ed25519, `~/.ssh/id_archvm`) verso il bastion e — via
  ProxyJump — verso i nodi interni e il DC.
- **`~/.ssh/config`** configurato per il salto via bastion (vedi sotto).
- **`.vault_pass`** con la password del Vault (per i segreti cifrati).
- **Risoluzione DNS del dominio** verso il DC (vedi *DNS della macchina di controllo*):
  senza, `kinit` fallisce con *"Cannot find KDC"* e i nomi `*.ad.lab.home` non si risolvono.

### Il `~/.ssh/config` (accesso via bastion)

Perché Ansible e l'uso a mano raggiungano i nodi interni attraverso il bastion senza
dipendere dall'ssh-agent, ogni nodo ha un blocco con **alias + FQDN + IP** e `ProxyJump`.
Il FQDN nei pattern serve per l'**SSO Kerberos** (il ticket è legato al nome completo):

```ssh-config
Host bastion 192.168.1.78
    HostName 192.168.1.78
    User ubuntu
    IdentityFile ~/.ssh/id_archvm

Host menu-app menu-app.ad.lab.home 192.168.1.72
    HostName menu-app.ad.lab.home
    User ubuntu
    IdentityFile ~/.ssh/id_archvm
    ProxyJump bastion
# ... blocchi analoghi per menu-lb (.75), menu-db (.73) ...

Host dc1 192.168.1.77
    HostName 192.168.1.77
    User ubuntu
    IdentityFile ~/.ssh/id_archvm
    ProxyJump bastion

# Login sul bastion come utente di dominio (per il flusso quotidiano)
Host bastion-ad
    HostName 192.168.1.78
    User mzelli@ad.lab.home
    PreferredAuthentications password
    PubkeyAuthentication no
    GSSAPIDelegateCredentials yes
```

L'IP nel blocco `Host` è essenziale: Ansible si connette per IP, e così eredita il
ProxyJump. Permessi: `chmod 600 ~/.ssh/config`.

### DNS della macchina di controllo (split-DNS al DC) — *config locale, NON IaC*

Il tuo PC deve mandare le query per `ad.lab.home` al DC (`192.168.1.77`), lasciando il
resto ai DNS pubblici. Poiché ha **una sola interfaccia**, la via pulita è il **plugin
dnsmasq di NetworkManager** con conditional forwarding:

```ini
# /etc/NetworkManager/conf.d/dns.conf
[main]
dns=dnsmasq
systemd-resolved=false
```
```
# /etc/NetworkManager/dnsmasq.d/ad-lab-home.conf
server=/ad.lab.home/192.168.1.77
```

E poiché in `/etc/nsswitch.conf` il modulo `resolve` precede `dns`, **systemd-resolved va
disattivato e mascherato** (socket compresi), altrimenti intercetta le query prima di
dnsmasq:

```bash
sudo systemctl disable --now systemd-resolved-varlink.socket systemd-resolved-monitor.socket
sudo systemctl mask --now systemd-resolved
sudo systemctl restart NetworkManager
```

> Questa è configurazione **del tuo PC**, fuori dall'IaC (il PC non è nell'inventory).
> Sui *nodi* del dominio il DNS verso il DC è gestito dal join AD/SSSD + `base_system`.

---

## Configurazione

### File `.env` (stack applicativo)

Lo stack legge la configurazione da variabili d'ambiente, tramite `lookup('env', ...)`
nei `group_vars/menu_stack/` e nei ruoli. Sono caricate da `.env` (**NON versionato** —
è nel `.gitignore`). Parti da `.env.example`:

```bash
cp .env.example .env    # poi compila i valori reali
```

Variabili chiave: `GIT_REPO`, `GIT_VERSION`, `DB_HOST`, `DB_PORT`, `DB_IMAGE`,
`LB_FRONTEND_PORT`, `LB_STATS_PORT`, `APP_CONFIG_PORT`. Le password e il token git stanno
nel **Vault**, non nel `.env`.

> Poiché i `lookup('env', ...)` leggono l'*ambiente della shell*, i playbook dello stack
> vanno lanciati tramite i wrapper (`avvio_servizi.sh`, `site.sh`) che fanno `source .env`.
> Un `ansible-playbook avvio_servizi.yml` **diretto** non caricherebbe il `.env`.
> *(Miglioria futura: migrare questi valori nei `group_vars`/Vault ed eliminare i wrapper.)*

### Ansible Vault (segreti)

I segreti cifrati vivono nei `group_vars/<gruppo>/vault.yml`:
- `group_vars/menu_stack/vault.yml`: password DB (utente e root), token git.
- `group_vars/ad_clients/vault.yml`: password di join al dominio AD.
- `group_vars/domain_controllers/vault.yml`: password admin del dominio, password di `mzelli`.

```bash
ansible-vault edit group_vars/menu_stack/vault.yml    # modificare
# .vault_pass + ansible.cfg (vault_password_file) evitano di digitare la password ogni volta
```

> Non esiste più `group_vars/all/`: i segreti sono stati spostati nei gruppi specifici a
> cui appartengono, così ogni segreto è visibile solo dove serve.

---

## Procedure di avvio

L'ordine conta: **base → identità → stack → firewall** (i nodi devono risolvere il DC
prima del join; il firewall si chiude per ultimo, a servizi già su).

### Opzione rapida: l'orchestratore `site.yml`

Da macchine "vuote" (già create da Terraform) a tutto pronto, con un comando:

```bash
chmod +x site.sh          # una volta sola
./site.sh --check         # prova a vuoto (carica .env e simula)
./site.sh                 # esecuzione reale
```

`site.yml` usa `ansible.builtin.import_playbook` per richiamare in ordine
`base.yml` → `ad.yml` → `avvio_servizi.yml` → `firewall.yml`. **Non** include `dc.yml`
(il ruolo `domain_controller` non va rilanciato sul DC vivo). `site.sh` fa `source .env`
prima di lanciare (necessario per lo stack).

### Passi singoli (uso granulare)

**1. Preparazione di base (rete IPv4-only)**
```bash
ansible-playbook base.yml
```
Depone il drop-in netplan che spegne RA e link-local IPv6 su `eth0` (vedi *Nota di design:
IPv6/RA*). Prerequisito: senza, gli RA del router iniettano DNS spuri e il join fallisce.

**2. Domain Controller — SOLO in disaster recovery**
```bash
ansible-playbook dc.yml        # ⚠️ NON eseguire sul DC vivo: ricostruisce il dominio
```
Il ruolo `domain_controller` sa provisionare un Samba AD-DC da zero. È "in cassetta" per
ricostruire `dc1` in caso di disastro; **non** va lanciato su un DC già funzionante.

**3. Integrazione AD + SSO**
```bash
ansible-playbook ad.yml
```
Unisce i nodi al dominio, configura ID mapping, login AD (solo dove previsto), GSSAPI/SSO,
e la config client del bastion.

**4. Stack applicativo**
```bash
./avvio_servizi.sh              # carica .env e lancia avvio_servizi.yml (hosts: menu_stack)
./avvio_servizi.sh --tags lb    # solo il load balancer
```

**5. Firewall (default deny)**
```bash
ansible-playbook firewall.yml   # nodi interni + DC: SSH solo dal bastion, porte AD alla LAN
```
Applica la cornice di sicurezza. **Paracadute admin spento di default** (vedi sotto).

### Cleanup dello stack
```bash
./cleanup_servizi.sh            # rimuove container/config dello stack (hosts: menu_stack)
```

---

## Il firewall in dettaglio

Il ruolo `firewall` gira su `internal` (lb/app/db) e su `domain_controllers` (dc1):

- **Policy**: default deny in ingresso, allow in uscita.
- **SSH**: consentito **solo dal bastion** (`firewall_bastion_ip`).
- **Porte di servizio**: aperte via il loop dichiarativo `firewall_service_rules`. Il DC
  le usa per le porte AD (DNS, Kerberos, LDAP/LDAPS, GC, SMB, kpasswd, RPC + range dinamico)
  aperte alla sola LAN (`firewall_dc_allowed_network`, in `group_vars/domain_controllers/`).
- **Paracadute admin**: **disattivato di default** (`firewall_admin_ip: ""`). A regime si
  entra solo dal bastion. Per un'operazione rischiosa lo si riaccende *solo per quel lancio*.

### Paracadute e lockdown (opt-in)

```bash
# Applica il firewall a un nodo tenendo APERTO un paracadute dal tuo PC:
ansible-playbook firewall.yml --limit <nodo> -e firewall_admin_ip=192.168.1.23
# ...verifica l'accesso via bastion..., poi rimuovi il paracadute:
ansible-playbook firewall.yml --limit <nodo> -e firewall_admin_ip=192.168.1.23 -e firewall_lockdown=true
```

> ⚠️ **DC**: è il nodo più critico (rompere il suo firewall = rompere DNS/Kerberos di
> tutto il dominio). Quando ci lavori, **riaccendi il paracadute per quel lancio** o tieni
> una sessione SSH aperta: `sudo ufw disable` dalla sessione è il vero rollback.

---

## Flusso quotidiano (accesso)

```bash
ssh bastion-ad                  # login sul bastion come mzelli (password AD)
ssh menu-app.ad.lab.home        # salto SSO al nodo, senza credenziali (ticket delegato)
```

Stats di HAProxy: `http://192.168.1.75:<LB_STATS_PORT>/stats` (es. `:8080/stats`).

---

## I ruoli

| Ruolo | Responsabilità |
|-------|----------------|
| `base_system` | rende i nodi IPv4-only (drop-in netplan: `accept-ra: false`, `link-local: []`) |
| `domain_controller` | provisioning Samba AD-DC da zero (**disaster recovery**, non sul DC vivo) |
| `ad_client` | join AD, ID mapping, login AD per `devops`, GSSAPI + localauth (SSO) |
| `bastion` | config client del bastion per il salto SSO ai nodi `*.ad.lab.home` |
| `firewall` | cornice di sicurezza: default deny + SSH solo dal bastion; porte via `firewall_service_rules` |
| `costruzione_progetto` | stack app: Docker, MySQL, deploy FastAPI, HAProxy (+ porte di servizio dello stack) |
| `project_cleanup` | rimozione dello stack applicativo |

### Utility

| File | Cosa fa |
|------|---------|
| `reset_host_keys.yml` | rimuove le host key obsolete dal `known_hosts` **locale** (per IP e FQDN) |

`reset_host_keys.yml` è ciò che rende sicuro `StrictHostKeyChecking=accept-new`: quando
ricrei una VM (stesso IP, chiave nuova), `accept-new` bloccherebbe; si rimuove la voce
stale e la connessione riparte. Uso: `ansible-playbook reset_host_keys.yml -e target=menu_stack`.

---

## Note di design

### Cornice vs servizi (firewall)

Il firewall ha **una sola fonte di verità per tipo di regola**:
- Il ruolo `firewall` possiede la **cornice**: SSH-solo-dal-bastion, default deny, enable,
  e il *meccanismo* per aprire porte extra (`firewall_service_rules`).
- Le **porte dello stack app** (3306 dai nodi app, porta app dal solo lb, 80/stats di
  HAProxy) restano nel ruolo `costruzione_progetto`, accanto al servizio che le usa.
- Le **porte del DC** (AD) sono dichiarate come *dato* in `group_vars/domain_controllers/`
  e applicate dal ruolo `firewall` via `firewall_service_rules`.

Si applica `firewall` *prima*, poi lo stack aggiunge i suoi fori. Nessuna sovrapposizione.

### IPv6 / RA: perché IPv4-only sui nodi

Il router annuncia via **IPv6 Router Advertisement (RA)** dei DNS IPv6 spuri (rDNS) che
`systemd-resolved` a volte preferisce al DC, rompendo la risoluzione di `ad.lab.home`.
`dhcp6: false` **non** basta a fermare gli RA, e il vecchio `disable_ipv6` via sysctl era
inefficace (systemd-networkd riaccende l'IPv6 sull'interfaccia). La cura è al **layer
netplan**, su due fronti:
- **Nodi vivi** → ruolo `base_system` (drop-in `/etc/netplan/99-ipv4-only.yaml`).
- **VM nuove** → `cloud_init.tf` del Terraform (stesso `accept-ra: false` + `link-local: []`).

### Host key: `accept-new`

`StrictHostKeyChecking=accept-new` (globale nell'inventory) accetta gli host **nuovi** ma
**rifiuta** se la chiave di un host noto cambia (protezione MITM), a differenza di `no`.
Il caso legittimo "chiave cambiata" (VM ricreata) si gestisce con `reset_host_keys.yml`.

### HAProxy idempotente

La config di HAProxy è generata da **un unico template** (`haproxy.cfg.j2`). Il task usa
`validate: haproxy -c`: se la config è invalida, non viene applicata e HAProxy non viene
riavviato con un file rotto. Idempotente per costruzione.

---

## Struttura del progetto

```
.
├── site.yml               # orchestratore: base -> ad -> stack -> firewall (import_playbook)
├── site.sh                # wrapper: carica .env e lancia site.yml
├── base.yml               # playbook: rete IPv4-only (base_system)
├── dc.yml                 # playbook: provisioning DC (disaster recovery)
├── ad.yml                 # playbook: integrazione AD + SSO
├── firewall.yml           # playbook: firewall (internal + domain_controllers)
├── avvio_servizi.yml      # playbook: stack applicativo (hosts: menu_stack)
├── avvio_servizi.sh       # wrapper: carica .env e lancia
├── cleanup_servizi.yml    # playbook: cleanup stack
├── cleanup_servizi.sh     # wrapper cleanup
├── reset_host_keys.yml    # utility: pulizia known_hosts locale
├── inventory.yml          # host e gruppi (IP = fonte unica) + ProxyJump/accept-new
├── ansible.cfg            # config (inventory, vault_password_file)
├── group_vars/
│   ├── ad_clients/        # vars.yml + vault.yml (password join AD)
│   ├── domain_controllers/# vars.yml (realm, porte AD firewall) + vault.yml
│   └── menu_stack/         # vars.yml (config stack) + vault.yml (segreti app)
├── host_vars/
│   └── lb.yml, app.yml, db.yml   # login AD disabilitato (nodi-servizio)
├── roles/
│   ├── base_system/  domain_controller/  ad_client/  bastion/  firewall/
│   ├── costruzione_progetto/     # templates/haproxy.cfg.j2, ecc.
│   └── project_cleanup/
└── docs/                   # runbook (bastion, AD) e riferimenti LDAP
```

---

## Comandi utili (debug, verifica)

```bash
# Identità AD e SSO
ansible app:db -m command -a "id mzelli@ad.lab.home" --become
ssh bastion-ad   # poi: ssh menu-db.ad.lab.home 'whoami; klist'

# DNS del dominio servito dal DC
host -t SRV _kerberos._udp.ad.lab.home 192.168.1.77   # atteso: dc1 porta 88
kinit mzelli@AD.LAB.HOME && klist                      # atteso: TGT rilasciato

# Firewall: regole reali (vista ufw)
ssh dc1 'sudo ufw status verbose'

# Diretto VERO bloccato? (deve andare in timeout, non Permission denied)
ssh -F /dev/null -i ~/.ssh/id_archvm -o ConnectTimeout=10 ubuntu@192.168.1.75 'echo test'

# Ansible raggiunge tutto via bastion?
ansible internal:domain_controllers -m ping

# Interfaccia IPv4-only? (nessun fe80:: su eth0)
ssh menu-lb 'resolvectl status | grep -A3 "Link.*eth0"; ip -6 addr show eth0'

# HAProxy: config valida + porte in ascolto
ssh menu-lb 'sudo haproxy -c -f /etc/haproxy/haproxy.cfg; sudo ss -tlnp | grep -E ":80|:8080"'
```

---

## Note operative e hardening futuri

- **Console d'emergenza del DC**: la VM `dc1` ha VNC ma l'utente `ubuntu` non ha password,
  quindi la console non è un vero paracadute. Recupero attuale: sessione SSH tenuta aperta
  → `sudo ufw disable`. Valutare una console seriale via Terraform + password d'emergenza.
- **IPv6 sul DC**: `base_system` gira sugli `ad_clients`, **non** sul DC (gruppo diverso).
  L'hardening IPv6 del DC è ancora da valutare separatamente.
- **`qemu-guest-agent`**: presente nel cloud-init delle VM nuove (per `virsh shutdown`
  pulito); le VM esistenti potrebbero non averlo finché non ricreate.
- **Passphrase della chiave** `id_archvm`: assente; da valutare per l'hardening.
- **IP admin DHCP**: il paracadute opzionale usa l'IP del PC (`.23`), dinamico via DHCP —
  verificare che corrisponda prima di usarlo (o riservarlo sul router).
- **Merge** `feature/bastion-host` → `main` (su questo repo e sul Terraform) quando stabile.
- **`app2`**: riattivarla (RAM permettendo) in inventory + Terraform; il backend HAProxy
  la include in automatico (il template cicla su `app_servers`).
- **Migrare `.env` → group_vars/Vault**: eliminerebbe i wrapper e il caricamento manuale.


## Provisioning da zero (ricostruzione completa, DC compreso)

Il flusso normale dà il **DC per esistente**: `site.yml` parte da `base` e assume che
`dc1` risponda già a DNS e Kerberos. In un *"rifaccio tutto"* il DC **non esiste ancora**,
e questo cambia l'ordine — perché quasi tutto dipende da lui.

### Il principio: le dipendenze di bootstrap

Il DC è il **fondamento** su cui poggia il resto:

- il **join al dominio** (`ad.yml`) ha bisogno che il DC risponda a **DNS + Kerberos**
  (`realm discover` fallisce se il DNS non vede il DC);
- il **DNS dei nodi membri** punta al DC: senza DC attivo, i nodi non risolvono `ad.lab.home`.

Regola: **il DC va creato per primo tra i servizi di dominio**, prima di configurare il resto.

### L'ordine corretto

```
Terraform (tutte le VM)  →  dc.yml  →  [verifica DC]  →  site.yml
                            └─ manuale, da solo ─┘        └─ base → ad → stack → firewall ─┘
```

**1. Terraform — crea tutte le VM (DC compreso).**
Nascono vuote ma già IPv4-only (il `cloud_init.tf` contiene `accept-ra: false` +
`link-local: []`, quindi niente RA/DNS spuri dal primo boot).
*Perché prima:* senza le macchine non c'è nulla da configurare.

**2. `dc.yml` — il DC, da solo, prima di tutto il resto.**
```bash
ansible-playbook dc.yml
```
Provisiona il Samba AD-DC: diventa il **DNS + KDC** del dominio.
*Perché qui:* finché non è su e funzionante, nessun nodo può unirsi al dominio.

**3. Verifica del DC — non saltarla.**
```bash
host -t SRV _kerberos._udp.ad.lab.home 192.168.1.77   # atteso: dc1, porta 88
kinit mzelli@AD.LAB.HOME && klist                      # atteso: TGT rilasciato
```
*Perché:* se il passo 4 parte contro un DC non pronto, fallisce a metà lasciando nodi
mezzi-joinati da ripulire. È un cancello di verifica prima di procedere.

**4. `site.yml` — tutto il resto, in ordine.**
```bash
./site.sh
```
Esegue `base` (IPv4-only sui nodi) → `ad` (join + SSO, ora che il DC risponde) →
`avvio_servizi` (stack) → `firewall` (per ultimo, a servizi su).

### Perché `dc.yml` è FUORI da `site.yml`

La separazione è **voluta**, per due motivi:

- **Sicurezza operativa (anti-piede-nel-grilletto):** `site.yml` è la routine che lanci
  spesso (ri-applicare config, aggiornare lo stack). Se `dc.yml` fosse dentro, ogni
  `./site.sh` rischierebbe di **ri-provisionare il DC vivo** — e il ruolo
  `domain_controller` su un DC già attivo fa danni (restart Samba, ri-provision).
- **Cadenza diversa:** il DC lo crei **una volta** (o lo ricostruisci in un disastro); lo
  stack e la config li ri-applichi **di continuo**. Cicli di vita diversi → comandi diversi.

In breve: `dc.yml` è un'operazione **eccezionale e manuale**; `site.yml` è la routine.

### ⚠️ Attenzione: ricostruire il DC significa un dominio NUOVO

Un DC ricostruito da zero è un **dominio nuovo** (SID, chiavi Kerberos e machine account
tutti nuovi). I nodi già joinati al *vecchio* DC non sono più validi contro quello nuovo:

- in un *"da zero assoluto"* (anche i nodi ripartono vuoti) → nessun problema;
- se ricostruisci **solo** il DC lasciando i nodi vivi → devi **ri-joinare tutti i nodi**
  (rilanciare `ad.yml`), perché il vecchio join non vale più.

È il motivo per cui `dc.yml` porta l'avviso *"disaster recovery, non sul DC vivo"*.
---

*Lab a scopo di studio, rete locale, software open-source.*

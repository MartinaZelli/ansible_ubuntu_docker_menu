# Bastion host — accesso mediato e nodi interni protetti

Documentazione del filone "bastion host" del lab: come è stato costruito, e —
soprattutto — gli imprevisti su cui siamo inciampati e come si risolvono. La
sezione [Imprevisti e lezioni](#imprevisti-e-lezioni) è la più preziosa: raccoglie
i problemi reali, non la teoria.

---

## Cos'è e perché

Un **bastion host** (o *jump host*) è l'**unica porta d'ingresso** all'infrastruttura.
Invece di fare SSH diretto a ogni nodo, ci si connette prima al bastion e *da lì* si
raggiungono gli altri. I nodi interni chiudono l'SSH a tutti tranne che al bastion.

Cosa si guadagna rispetto all'accesso diretto "dal mio PC a tutto":
- **Superficie d'attacco ridotta a uno**: solo il bastion è esposto; i nodi interni
  accettano SSH solo da lui.
- **Identità per persona via AD**: si fa login col proprio account di dominio
  (`mzelli@ad.lab.home`), non con una chiave anonima condivisa. Accessi tracciati.
- **Controllo centralizzato**: disabilitare un account su AD revoca l'accesso a *tutta*
  l'infrastruttura in un colpo solo.

### Topologia

```
ACCESSO DIRETTO (prima)          CON BASTION (dopo)
  PC ──> app                       PC ──> [ BASTION ] ──> app
  PC ──> db                                        ├──> db
  PC ──> lb                                        ├──> lb
  (ogni nodo esposto)              (solo il bastion esposto;
                                    i nodi accettano SSH solo dal bastion)
```

> **Nota sull'isolamento nel lab**: la rete è *piatta* (tutte le VM su
> `192.168.1.0/24`, stesso bridge). Non c'è segmentazione di rete fisica tra bastion
> e nodi interni: l'isolamento lo fa il **firewall su ogni host** (`ufw`), NON il
> routing. In produzione si aggiungerebbe la segmentazione (subnet/VLAN/security
> group) come seconda barriera. Saper articolare questa differenza è già maturità
> architetturale.

---

## I nodi

| Nodo | IP | Ruolo nel modello bastion |
|------|-----|---------------------------|
| `bastion` | 192.168.1.78 | L'unica porta d'ingresso. Client AD con login umani. |
| `lb` | 192.168.1.75 | Nodo interno protetto: SSH solo dal bastion. |
| `dc1` | 192.168.1.77 | Domain Controller (autentica i login AD). |

> In questa iterazione solo `lb` è "dietro" il bastion (collaudo del pattern a basso
> costo di RAM). Quando si ricreeranno `app`/`app2`/`db`, erediteranno lo stesso
> pattern applicando i ruoli `ad_client` + `firewall`.

---

## I componenti costruiti

### 1. VM bastion (Terraform)

Aggiunta una voce in `locals.tf` (`vms_raw`): hostname `bastion`, IP `.78`, MAC nuovo,
`ad_member = true` di default. Grazie al pattern `ad_member`, nasce già con FQDN
`bastion.ad.lab.home`, DNS puntato al DC e `/etc/hosts` corretto — zero configurazione
di rete a mano.

### 2. Ruolo `ad_client` (join al dominio AD)

Unisce un host al dominio in modo **idempotente**. Principi:
- **Separazione delle responsabilità**: il ruolo fa *solo* il join + la config SSSD.
  La rete (DNS, FQDN, hosts) è già stata sistemata da Terraform/cloud-init.
- **Idempotenza "controlla-poi-agisci"**: `realm join` non è idempotente, quindi un
  task *legge* lo stato (`realm list`) e il join è condizionato (`when: non già membro`).
- **Segreto nel vault**: la password di join sta in `group_vars/ad_clients/vault.yml`
  (cifrata), mappata in `vars.yml` come `ad_client_join_password: "{{ vault_ad_join_password }}"`.
- **Gestione esplicita dell'ID mapping** (`ldap_id_mapping`) con handler che svuota la
  cache SSSD quando cambia.

### 3. ProxyJump (accesso mediato)

Far passare SSH e Ansible *attraverso* il bastion. Due livelli:
- **`~/.ssh/config`** (per l'uso a mano e — fondamentale — anche per Ansible): vedi
  [Configurazione SSH](#configurazione-ssh-di-riferimento).
- **Inventory**: gruppo `internal` con `lb`, che eredita lo strict checking.

### 4. Ruolo `firewall` (lockdown a due tempi)

Applica `ufw` su `lb`: default deny in ingresso, SSH permesso solo dal bastion.
Costruito con la strategia **anti-lockout a due tempi** (vedi sotto).

---

## Configurazione SSH di riferimento

Il file `~/.ssh/config` che rende il ProxyJump **stabile** (senza dipendere dall'agent):

```ssh-config
# Bastion: raggiunto direttamente, con la sua chiave
Host bastion 192.168.1.78
    HostName 192.168.1.78
    User ubuntu
    IdentityFile ~/.ssh/id_archvm

# lb: raggiunta SALTANDO dal bastion (per alias E per IP)
Host menu-lb 192.168.1.75
    HostName 192.168.1.75
    User ubuntu
    IdentityFile ~/.ssh/id_archvm
    ProxyJump bastion
```

Permessi: `chmod 600 ~/.ssh/config` (SSH ignora il file se è troppo permissivo).

Dettaglio cruciale: ogni blocco `Host` elenca **sia l'alias sia l'IP**
(`Host menu-lb 192.168.1.75`). Così la regola scatta sia con `ssh menu-lb` sia quando
ci si connette all'IP nudo `192.168.1.75` — ed è quest'ultimo il caso di Ansible, che
usa `ansible_host: 192.168.1.75`. Senza l'IP nel blocco, Ansible non beneficerebbe del
config. Vedi [l'imprevisto sull'agent](#4-proxyjump-fragile-lagent-ssh-che-sparisce).

Con questo config, raggiungere `lb` è trasparente — basta l'IP, il salto avviene da solo:
```bash
ssh 192.168.1.75 'hostname -f'   # passa dal bastion automaticamente
```

---

## Imprevisti e lezioni

La parte che conta. Ogni voce: *sintomo → causa → soluzione → lezione*.

### 1. `publickey denied`: la chiave SSH non era nell'inventory

- **Sintomo**: `ansible ... -m ping` → `Permission denied (publickey)`, anche se l'SSH
  a mano funzionava.
- **Causa**: nel blocco `vars:` dell'inventory mancava
  `ansible_ssh_private_key_file: ~/.ssh/id_archvm`. Ansible provava le chiavi di default
  e veniva rifiutato.
- **Soluzione**: aggiungere quella riga sotto `all: > vars:`.
- **Diagnosi**: `ansible -i inventory.yml HOST -m debug -a "var=ansible_ssh_private_key_file"`
  → se è `undefined`, è quello.
- **Lezione**: il **percorso** della chiave nell'inventory NON è un segreto (è solo un
  indirizzo). Il segreto è il *contenuto* della chiave privata, che non va mai nel repo.
  Versionare il percorso va bene e rende il repo auto-documentante.

### 2. Variabile `is undefined`: il nome è un contratto

- **Sintomo**: il task di join falliva con `'ad_client_join_password' is undefined`.
- **Causa**: in `group_vars/ad_clients/vars.yml` la chiave era scritta `ad_join_password`
  (nome vecchio), ma il ruolo cercava `ad_client_join_password` (refuso post-rinomina).
- **Soluzione**: allineare il nome — identico carattere per carattere.
- **Diagnosi**: confrontare definizione e uso a colpo d'occhio:
  ```bash
  grep -oE '^ad_[a-z_]+:' group_vars/ad_clients/vars.yml      # chi definisce
  grep -oE 'ad_client_join_password' roles/ad_client/tasks/main.yml  # chi usa
  ```
- **Lezione**: il nome di una variabile è un **contratto** tra chi la definisce e chi la
  usa. Un solo carattere di differenza e la variabile è "un'altra". Ansible non avvisa
  "forse intendevi", dice solo `undefined`. Primo sospetto su `undefined`: il nome combacia?

### 3. Le regole di `ansible-lint` (var prefix, changed_when, moduli)

Tre regole incontrate scrivendo i ruoli, tutte sensate:

- **`var-naming[no-role-prefix]`**: le variabili *dentro un ruolo* vanno prefissate col
  nome del ruolo (`ad_client_domain`, non `ad_domain`). Motivo: in Ansible le variabili
  vivono in uno spazio condiviso; il prefisso previene collisioni silenziose tra ruoli.
  *Eccezione*: i file in `group_vars/` NON sono "dentro il ruolo", quindi lì il nome è
  quello che il ruolo si aspetta (es. `ad_client_join_password`), senza imporre prefissi
  per la regola.

- **`no-changed-when`**: ogni task `command`/`shell` va etichettato. Se *legge* soltanto
  (`realm list`, `realm discover`, `grep`) → `changed_when: false`. Se *modifica* ed è già
  limitato da un `when:` → `changed_when: true`. Motivo: l'output di Ansible deve essere
  onesto (distinguere "ha letto" da "ha cambiato").

- **`command-instead-of-module`**: usare il modulo invece del comando grezzo. `systemctl`
  → modulo `systemd_service`; `rm` di un file → modulo `file: state: absent`. Motivo: i
  moduli sono idempotenti e consapevoli dello stato. Per raggruppare più task sotto una
  notifica unica si usa `listen: <nome>` negli handler.

- **Lezione**: il linter è un **insegnante di convenzioni**. Usarlo *durante* la scrittura
  (non dopo) fa nascere il codice già pulito. Obiettivo raggiunto: profilo `production`
  (lo standard più severo) su entrambi i ruoli.

### 4. ProxyJump fragile: l'agent SSH che sparisce

- **Sintomo**: `ssh -J ... ` e `ansible ... -m ping` fallivano con
  `Connection closed by UNKNOWN port 65535`, in modo intermittente (a volte sì a volte no).
- **Causa**: `ssh -J` autentica al *jump host* (il bastion) preferendo la chiave
  nell'**ssh-agent**. L'agent però muore alla chiusura del terminale → riaprendo, il salto
  falliva. `-i` da solo non bastava per il jump host.
- **Soluzione temporanea**: `eval "$(ssh-agent -s)"; ssh-add ~/.ssh/id_archvm`.
- **Soluzione stabile** (quella giusta): mettere il ProxyJump in **`~/.ssh/config`** con
  `IdentityFile` esplicito (vedi [config](#configurazione-ssh-di-riferimento)). Così la
  chiave è sempre associata, senza agent. Poi **togliere** il `ProxyJump` duplicato
  dall'inventory (era la versione fragile che ricadeva sull'agent), lasciando solo:
  ```yaml
  internal:
    hosts:
      lb:
    vars:
      ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
  ```
- **Lezione**: far dipendere il ProxyJump dall'agent è fragile. Centralizzare la config di
  connessione in `~/.ssh/config` con chiave esplicita è la pratica standard, robusta e
  riusabile sia a mano sia da Ansible.

### 5. ID mapping: cambiare schema su un nodo già joinato è ostico

- **Sintomo**: volendo portare `lb` da POSIX esplicito (`uid=10000`) all'ID mapping
  automatico (`uid` calcolato dal SID), il cambio di `ldap_id_mapping` in `sssd.conf` +
  svuotamento cache **non aveva effetto**: `id mzelli` continuava a dare il vecchio valore.
- **Causa**: SSSD conserva lo *stato del dominio* (incluso il modo di mappare gli ID) in
  strutture che sopravvivono al solo svuotamento della cache utenti. Cambiare schema su un
  dominio già inizializzato non è supportato come semplice modifica di config.
- **Soluzione**: ricreare la VM da zero (vergine) e rifare il join pulito → SSSD genera lo
  stato del dominio corretto fin dall'inizio. (`lb` andava comunque ricreata per HAProxy,
  quindi nessuno spreco.)
- **Lezione**: a volte la soluzione pulita è "**ricrea da zero**" invece di accanirsi su un
  nodo "sporco". È la filosofia *cattle, not pets*. E: il modo supportato per cambiare ID
  mapping è `realm leave` + ri-join, non l'editing a caldo.

### 6. Account-computer orfano su AD dopo la distruzione di una VM

- **Sintomo**: distruggendo `lb` con `virsh` (senza `realm leave`), su AD resta un
  account-macchina orfano.
- **Soluzione**: rimuoverlo sul DC. Attenzione al nome: è basato sull'**hostname**, non
  sulla chiave Terraform:
  ```bash
  sudo samba-tool computer list | grep -i lb     # mostra MENU-LB$
  sudo samba-tool computer delete MENU-LB        # senza il $ finale
  ```
- **Lezione**: distruggere una VM membro di dominio lascia residui su AD. `samba-tool
  computer list` prima di cancellare (verifica il nome reale, non indovinarlo).

### 7. Host key SSH cambiata dopo aver ricreato la VM

- **Sintomo**: `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` connettendosi alla nuova
  `lb` sullo stesso IP.
- **Causa**: la nuova VM ha una chiave host diversa dalla vecchia; SSH protegge da un
  possibile man-in-the-middle.
- **Soluzione**: rimuovere la vecchia chiave da `known_hosts` e riaccettare:
  ```bash
  ssh-keygen -R 192.168.1.75
  ```
- **Lezione**: atteso e benigno *quando sei tu* a ricreare la VM. In altri contesti, quel
  warning NON va ignorato a cuor leggero (è proprio l'allarme anti-MITM).

### 8. Firewall: `PLAY RECAP` verde ≠ effetto applicato

- **Sintomo**: dopo il lockdown, il `PLAY RECAP` diceva `changed` (rimozione paracadute
  riuscita), ma l'accesso diretto al PC sembrava ancora funzionare.
- **Causa (vera)**: non era il firewall a fallire. Il `~/.ssh/config` instradava la
  connessione all'IP `.75` *attraverso il bastion* automaticamente (perché il blocco
  `Host` include l'IP con `ProxyJump`). Quindi non era un accesso "diretto": era un salto
  mascherato, che il firewall giustamente permette.
- **Diagnosi che ha chiarito tutto**: bypassare il config per forzare una connessione
  davvero diretta:
  ```bash
  ssh -F /dev/null -i ~/.ssh/id_archvm -o ConnectTimeout=10 ubuntu@192.168.1.75 'echo test'
  # -> Connection timed out  =  il diretto È bloccato (successo!)
  ```
  E verificare le regole reali nel kernel, non solo la lista ufw:
  ```bash
  sudo iptables -L ufw-user-input -n --line-numbers   # solo .78, corretto
  ```
- **Lezione doppia**:
  1. Il `PLAY RECAP` dice cosa Ansible *ha tentato*; la **verifica funzionale** dice cosa è
     *realmente successo*. Verificare sempre l'effetto, non fidarsi del "changed".
  2. Un `~/.ssh/config` ben fatto può *mascherare* il comportamento del firewall
     instradando silenziosamente dal bastion. Per testare il "diretto vero", bypassare il
     config con `-F /dev/null`.

---

## Strategia anti-lockout (riferimento operativo)

Chiudere l'SSH su un nodo remoto è l'unica operazione che può tagliarti fuori. Regole:

1. **Ordine delle regole nel ruolo**: prima le policy di default, poi le regole
   *permissive* (eccezioni), e `ufw enabled` **per ultimo**. Quando ufw si attiva, le
   eccezioni esistono già — nessun istante "tutto chiuso".
2. **Due tempi**:
   - *Tempo 1*: permetti SSH dal bastion **e** dal tuo PC (paracadute). Attiva ufw.
     Verifica che la via bastion funzioni.
   - *Tempo 2*: rimuovi il paracadute del PC (variabile `firewall_lockdown=true`). Solo il
     bastion resta.
3. **Ansible passa dal bastion** (gruppo `internal` + ProxyJump): applica le regole *da
   dentro*, quindi non si taglia fuori da solo.
4. **Verifica nell'ordine giusto** dopo il lockdown: prima che la via bastion FUNZIONI,
   *poi* che il diretto sia BLOCCATO. Mai togliere il paracadute senza aver confermato la
   via bastion.

### Paracadute di emergenza: la console libvirt

Indipendente dalla rete e dal firewall (entra "da sotto"):
```bash
sudo virsh console menu-lb       # uscita: Ctrl + ]
```
> Per usarla serve un login con password sull'account della VM (di default l'utente
> `ubuntu` da cloud-init non ne ha). Da valutare *se* si vuole questo paracadute attivo.

### Annullare il firewall in emergenza
```bash
sudo ufw disable
```

---

## Comandi di verifica utili

```bash
# Stato firewall (vista ufw)
ssh 192.168.1.75 'sudo ufw status verbose'

# Regole reali nel kernel (la verità, oltre la vista ufw)
ssh 192.168.1.75 'sudo iptables -L ufw-user-input -n --line-numbers'

# La via bastion funziona? (deve passare)
ssh -o ConnectTimeout=10 192.168.1.75 'echo VIA-BASTION-OK'

# Il diretto vero è bloccato? (deve andare in timeout)
ssh -F /dev/null -i ~/.ssh/id_archvm -o ConnectTimeout=10 ubuntu@192.168.1.75 'echo test'

# Ansible passa dal bastion?
ansible -i inventory.yml lb -m ping

# Stato del join AD + identità
ssh 192.168.1.75 'realm list | grep -E "configured|permitted-groups"; id mzelli@ad.lab.home'
```

---

## Stato finale

Il modello bastion è completo:
- ✅ VM `bastion` (Terraform), nata già integrata nel dominio.
- ✅ `ad_client`: join idempotente, login ristretto a `devops`, ID mapping uniforme.
- ✅ ProxyJump stabile via `~/.ssh/config` (no dipendenza dall'agent).
- ✅ `firewall`: `lb` accetta SSH solo dal bastion; il diretto è murato.

Da "SSH diretto a tutto dal mio PC" a "unica porta d'ingresso autenticata via AD, nodi
interni protetti". Tutto costruito da codice: Terraform per le VM, Ansible per AD +
accesso + firewall.

---

*Lab a scopo di studio, rete locale, software open-source. Branch: `feature/bastion-host`.*

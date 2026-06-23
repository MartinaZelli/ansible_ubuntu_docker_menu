# Pratica: Active Directory con Samba (DC + client Linux)

Runbook della sessione pratica: costruzione manuale di un domain controller
**Samba AD DC** e unione di un client Linux al dominio con **SSSD** (modalità `ad`).
Companion del documento `teoria_active_directory.md`.

**Ambiente:** lab libvirt/KVM, VM Ubuntu 24.04, rete `192.168.1.0/24`, solo
software open-source.

**Parametri del dominio creato oggi:**
- Realm Kerberos: `AD.LAB.HOME` · dominio NetBIOS: `AD` · DNS domain: `ad.lab.home`
- DC: hostname `dc1`, FQDN `dc1.ad.lab.home`, IP `192.168.1.77`
- Client: `lb`, IP `192.168.1.75`
- DOMAIN SID: `S-1-5-21-1285797844-2080138173-1106835379`
- ID mapping SID→UID: **algoritmico** (`ldap_id_mapping = True`)

> Nota di metodo: per AD il DC non si costruisce "mattone su mattone" come slapd —
> si provisiona in un comando. Il valore del manuale qui è *vedere i concetti in
> azione* (Kerberos, DNS, SID), non costruire incrementalmente.

---

## PARTE A — Il Domain Controller (`dc1`)

### A0. La VM (Terraform)

Voce in `local.vms_raw` (`locals.tf`):
```hcl
"dc" = {
  hostname = "dc1"
  ip       = "192.168.1.77"
  mac      = "02:00:00:01:00:06"
  memory   = 4096          # IMPORTANTE: 2048 non bastano (vedi Errore #2)
  vcpu     = 2
}
```
```bash
cd terraform_exercise
tofu apply -replace='libvirt_volume.vm_disk["dc"]' -replace='libvirt_domain.vm["dc"]'
```

### A1. Identità della macchina
```bash
sudo hostnamectl set-hostname dc1
sudo tee /etc/hosts >/dev/null <<'EOF'
127.0.0.1   localhost
192.168.1.77   dc1.ad.lab.home   dc1
EOF
```
*Perché:* il FQDN deve puntare all'IP reale; Kerberos e i record DNS dipendono da
una mappatura nome↔IP corretta.

### A2. Resolver TEMPORANEO per l'installazione
```bash
sudo tee /etc/resolv.conf >/dev/null <<'EOF'
nameserver 192.168.1.1
nameserver 8.8.8.8
search ad.lab.home
EOF
```
*Perché:* il resolver definitivo (`127.0.0.1`) ha senso solo DOPO che Samba è
avviato e ascolta sulla 53. Prima serve un DNS reale per scaricare i pacchetti
(vedi Errore #1).

### A3. Installazione
```bash
sudo apt update
sudo apt install -y samba-ad-dc krb5-user bind9-dnsutils
```
(`krb5-user` chiede il default realm via debconf → `AD.LAB.HOME`.)

### A4. Resolver DEFINITIVO (solo ora, prima del provisioning)
```bash
sudo tee /etc/resolv.conf >/dev/null <<'EOF'
nameserver 127.0.0.1
search ad.lab.home
EOF
```

### A5. Provisioning del dominio
```bash
sudo mv /etc/samba/smb.conf /etc/samba/smb.conf.orig 2>/dev/null || true

sudo samba-tool domain provision \
  --use-rfc2307 \
  --realm=AD.LAB.HOME \
  --domain=AD \
  --server-role=dc \
  --dns-backend=SAMBA_INTERNAL \
  --adminpass='<PasswordComplessa>'      # 8+ caratteri, maiuscola, cifra
```
Significato dei flag:
- `--realm` / `--domain`: realm Kerberos e nome NetBIOS breve.
- `--server-role=dc`: questa macchina è un domain controller.
- `--dns-backend=SAMBA_INTERNAL`: DNS integrato di Samba (semplice, per lab).
- `--use-rfc2307`: abilita gli attributi POSIX (`uidNumber`/`gidNumber`) nello
  schema → ponte verso Linux per un eventuale mapping a attributi.

A fine provisioning viene stampato il **DOMAIN SID** (nasce qui, è immutabile).

### A6. Kerberos + avvio del servizio
```bash
sudo cp /var/lib/samba/private/krb5.conf /etc/krb5.conf   # COPIA, non symlink

sudo systemctl disable --now smbd nmbd winbind 2>/dev/null || true
sudo systemctl mask smbd nmbd winbind 2>/dev/null || true   # in modalità DC li ingloba samba-ad-dc
sudo systemctl unmask samba-ad-dc
sudo systemctl enable --now samba-ad-dc
sudo systemctl status samba-ad-dc --no-pager
```

### A7. Forwarder DNS (per risolvere i nomi esterni)
In `[global]` di `/etc/samba/smb.conf`:
```ini
[global]
        dns forwarder = 192.168.1.1     # ATTENZIONE al refuso (vedi Errore #4)
```
```bash
sudo systemctl restart samba-ad-dc
```

### A8. Verifica del DC
```bash
timedatectl                                  # Kerberos è sensibile al tempo
host -t SRV _ldap._tcp.ad.lab.home           # -> dc1.ad.lab.home:389
host -t SRV _kerberos._udp.ad.lab.home       # -> dc1.ad.lab.home:88
host -t A   dc1.ad.lab.home                   # -> 192.168.1.77
kinit administrator@AD.LAB.HOME              # ticket Kerberos
klist                                         # -> krbtgt/AD.LAB.HOME (il TGT)
sudo samba-tool user list                     # Administrator, Guest, krbtgt
```

---

## PARTE B — Creare oggetti nel dominio (`samba-tool`)

```bash
sudo samba-tool user create mzelli '<PasswordComplessa>' \
  --given-name=Martina --surname=Zelli
sudo samba-tool group add devops
sudo samba-tool group addmembers devops mzelli

sudo samba-tool user list
sudo samba-tool group listmembers devops
sudo samba-tool user show mzelli | grep -i objectSid
```
*Perché:* in AD l'utente è un **oggetto unificato** — `samba-tool user create` lo
crea completo in un comando (non `inetOrgPerson` + `posixAccount` separati).

**Il SID dell'oggetto** (esempio reale di oggi):
```
objectSid: S-1-5-21-1285797844-2080138173-1106835379-1103
            └──────── DOMAIN SID ───────────────────┘ └RID┘
```
Il prefisso è il SID del dominio; `-1103` è il RID (univoco dentro il dominio).

---

## PARTE C — Unire il client Linux al dominio (`lb`)

> Si è scelto di **ricostruire `lb` pulita**: aveva la config SSSD del client LDAP
> (`id_provider = ldap`), che `realm join` avrebbe mescolato. Tela bianca = niente
> conflitti.

### C0. Ricostruisci pulita
```bash
cd terraform_exercise
tofu apply -replace='libvirt_volume.vm_disk["lb"]' -replace='libvirt_domain.vm["lb"]'
ssh -i ~/.ssh/id_archvm ubuntu@192.168.1.75
```

### C1. Punta il DNS al DC (netplan)
`/etc/netplan/50-cloud-init.yaml`, sezione dell'interfaccia:
```yaml
      nameservers:
        addresses:
          - 192.168.1.77        # SOLO il DC (vedi Errore #5 per la sintassi)
        search:
          - ad.lab.home
```
```bash
sudo netplan generate     # valida la sintassi senza applicare
sudo netplan apply
```
*Perché un solo nameserver:* il client di dominio deve usare il DNS del DC in modo
**esclusivo**. Lasciare anche DNS pubblici causa fallimenti intermittenti (un DNS
pubblico non conosce `ad.lab.home` e risponde "non esiste"). Il DC risolve
`ad.lab.home` (autoritativo) e **inoltra** il resto al forwarder.

Verifica DNS:
```bash
resolvectl status                            # DNS Servers deve iniziare con 192.168.1.77
host -t SRV _ldap._tcp.ad.lab.home           # interno -> dc1
host archive.ubuntu.com                       # esterno -> risolve (via forwarder del DC)
```

### C2. Sincronizzazione oraria (Kerberos)
```bash
timedatectl
# robustezza opzionale:
sudo apt install -y chrony
echo "server dc1.ad.lab.home iburst prefer" | sudo tee -a /etc/chrony/chrony.conf
sudo systemctl restart chrony
```

### C3. Installa lo stack AD-client
```bash
sudo apt update
sudo apt install -y realmd sssd sssd-tools sssd-ad adcli samba-common-bin krb5-user packagekit
```

### C4. Scopri e unisci
```bash
sudo realm discover ad.lab.home              # trova il dominio via DNS (configured: no)
sudo realm join --user=Administrator ad.lab.home    # successo = nessun output
```
*Cosa fa `realm join` (al posto tuo):* crea l'account-computer in AD (anche la
macchina ha un SID), genera il keytab Kerberos (`/etc/krb5.keytab`), scrive
`/etc/sssd/sssd.conf` (`id_provider = ad`, `ldap_id_mapping = True`), configura
PAM e NSS.

### C5. Ritocchi: home + autorizzazione per gruppo
```bash
sudo pam-auth-update --enable mkhomedir
sudo realm permit -g devops@ad.lab.home      # solo i membri di devops possono entrare
```
*`realm permit -g`* è il gemello AD di `simple_allow_groups = devops` del client LDAP.

### C6. Verifica — il cerchio si chiude
```bash
realm list                                   # configured: kerberos-member
id mzelli@ad.lab.home                         # UID calcolato dal SID (ID mapping)
kinit mzelli@AD.LAB.HOME                      # ticket Kerberos DAL CLIENT
klist                                         # krbtgt/AD.LAB.HOME
su - mzelli@ad.lab.home                       # login: auth(Kerberos)+authz(devops)+home
```
Esempio reale di oggi: `id` ha dato `uid=1494601103(mzelli@ad.lab.home)` — l'UID
finisce in `...1103`, cioè il RID `-1103` mappato algoritmicamente. SID → UID, in atto.

---

## ERRORI AFFRONTATI OGGI (e come si risolvono)

### #1 — `apt`: "Temporary failure resolving 'archive.ubuntu.com'"
**Causa:** avevo impostato `resolv.conf` su `nameserver 127.0.0.1` *prima* che Samba
fosse installato/avviato → nessun DNS in ascolto su 127.0.0.1 → niente si risolve.
**Soluzione:** usare un resolver temporaneo (router/DNS pubblico) per installare, e
mettere `127.0.0.1` solo dopo il provisioning.
**Lezione:** "stacca vecchio DNS" e "attacca nuovo DNS" hanno una finestra in mezzo
senza DNS; l'ordine delle operazioni conta.

### #2 — Provisioning bloccato (dash ferma minuti, SSH non risponde)
**Causa:** VM con 2 GB di RAM; durante il *repack* del database Samba swappava, la
macchina era satura (non accettava nemmeno nuove sessioni SSH).
**Soluzione:** non interrompere un provisioning a metà (lascia DB inconsistente);
ricostruire la VM con `memory = 4096` e rifare.
**Lezione:** dimensionamento. slapd gira con 1 GB; un DC (LDAP+KDC+DNS+repack DB) è
un'altra fascia di carico.

### #3 — `samba-ad-dc` attivo ma DNS in errore: "Failed to bind to 0.0.0.0:53 — ADDRESS_ALREADY_ASSOCIATED"
**Causa:** dopo il rebuild della VM, `systemd-resolved` era tornato attivo e teneva
la porta 53 (il `disable` precedente viveva sulla vecchia VM).
**Soluzione:**
```bash
sudo systemctl disable --now systemd-resolved
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf >/dev/null <<'EOF'
nameserver 127.0.0.1
search ad.lab.home
EOF
sudo systemctl restart samba-ad-dc
sudo ss -tulpn | grep ':53'        # ora dev'essere 'dns[master]' (samba), non systemd-resolve
```
**Lezione:** il DC esige la porta 53 in esclusiva. Una config "che deve sopravvivere
al rebuild" va messa nell'automazione/cloud-init (a mano ce la si dimentica).

### #4 — Client: nome interno risolve, esterno (`archive.ubuntu.com`) no
**Causa:** refuso nel `dns forwarder` del DC (`168.1.1.1` invece di `192.168.1.1`)
→ il DC non sapeva a chi inoltrare le query non sue.
**Soluzione:** correggere `dns forwarder = 192.168.1.1` in `smb.conf` del DC e
`sudo systemctl restart samba-ad-dc`.
**Diagnosi utile:** `host archive.ubuntu.com 192.168.1.77` (interroga il DC
direttamente) isola se il problema è l'inoltro.
**Lezione:** due ruoli distinti del DNS — *autoritativo* (per `ad.lab.home`) e
*forwarder* (per il resto). Il DC deve fare entrambi.

### #5 — netplan: lista annidata sbagliata
**Causa:** mescolati i due stili di lista YAML → `- [192.168.1.77]` crea una lista
dentro una lista.
**Soluzione:** usare un solo stile. Block style corretto:
```yaml
      nameservers:
        addresses:
          - 192.168.1.77        # trattino SENZA parentesi quadre
        search:
          - ad.lab.home
```
**Strumento:** `sudo netplan generate` valida la sintassi senza applicare.
**Lezione:** in YAML le liste sono `[a, b]` (flow) OPPURE `- a` / `- b` (block), mai
mischiate.

---

## LDAP (manuale) vs AD (`realm join`) — cosa cambia

| | Client LDAP (a mano) | Client AD (realm join) |
|---|---|---|
| Trovare il server | `ldap_uri` + `/etc/hosts` | **discovery DNS** (record SRV) |
| Autenticazione | bind LDAP | **Kerberos** (TGT + SSO) |
| Fiducia/cert | CA distribuita a mano (slurp+copy) | gestita dal join |
| `sssd.conf` | scritto riga per riga | **scritto da `realm`** |
| Identità Unix | `posixAccount` creati a mano | **SID → UID** algoritmico |
| Autorizzazione | `simple_allow_groups = devops` | `realm permit -g devops@...` |

I tre pilastri (Kerberos, DNS, oggetto/SID unificato) si fanno carico del lavoro
che su LDAP era manuale.

---

## SPECCHIETTO — Sigle e acronimi

| Sigla | Significato | In una riga |
|---|---|---|
| **AD** | Active Directory | Directory + Kerberos + DNS + Group Policy di Microsoft (qui via Samba). |
| **DC** | Domain Controller | Il server del dominio: fa LDAP + KDC + (spesso) DNS. |
| **Samba AD DC** | — | Implementazione open-source di un DC compatibile AD. |
| **LDAP** | Lightweight Directory Access Protocol | Il protocollo di directory; nucleo anche di AD. |
| **DIT** | Directory Information Tree | L'albero gerarchico delle entry/oggetti. |
| **DN / RDN** | Distinguished Name / Relative DN | Percorso assoluto / pezzo più a sinistra. |
| **Kerberos** | — | Autenticazione a ticket (no password a ogni accesso). |
| **KDC** | Key Distribution Center | Il "quartier generale" Kerberos; gira sul DC. Contiene AS + TGS. |
| **AS** | Authentication Service | Lo sportello "ingresso" del KDC: rilascia il TGT. |
| **TGS** | Ticket Granting Service | Lo sportello "pass": dal TGT rilascia i service ticket. |
| **TGT** | Ticket Granting Ticket | Il "braccialetto": prova che ti sei autenticato; dura ore. |
| **service ticket** | — | Il "pass" per un servizio specifico, cifrato con la chiave del servizio. |
| **realm** | — | Il dominio Kerberos, per convenzione in MAIUSCOLO (`AD.LAB.HOME`). |
| **principal** | — | Un'identità Kerberos (`mzelli@AD.LAB.HOME`, `host/...@...`). |
| **keytab** | key table | File con la chiave di un servizio/computer per prendere ticket senza digitare password. |
| **SID** | Security Identifier | Identità immutabile per la sicurezza (utente/gruppo/computer). |
| **RID** | Relative Identifier | L'ultima parte del SID, univoca dentro il dominio. |
| **DNS** | Domain Name System | Qui anche per *service discovery* (record SRV). |
| **SRV record** | — | Record DNS che dice "il servizio X sta su quell'host:porta". |
| **SSSD** | System Security Services Daemon | Il "mediatore" tra OS (NSS/PAM) e la directory. |
| **NSS** | Name Service Switch | Risolve identità (UID/GID/home/shell). |
| **PAM** | Pluggable Authentication Modules | Gestisce auth/account/session al login. |
| **realmd** | — | Tool (`realm`) che scopre/unisce a un dominio e configura SSSD. |
| **adcli** | — | Utility per operazioni di join AD (usata da realmd). |
| **ID mapping** | — | Traduzione algoritmica SID → UID/GID (`ldap_id_mapping=True`). |
| **RFC 2307** | — | Schema con attributi POSIX (`uidNumber`/`gidNumber`) in directory. |
| **OU** | Organizational Unit | Contenitore; in AD anche unità di delega e Group Policy. |
| **GPO** | Group Policy Object | Regole di config applicate in automatico (assente in LDAP puro). |
| **FSMO** | Flexible Single Master Operations | Ruoli che un solo DC svolge (es. RID Master). |
| **FQDN** | Fully Qualified Domain Name | Nome completo (`dc1.ad.lab.home`). |

---

## PROSSIMI PASSI (per le prossime sessioni)

1. **Approfondimento POSIX**: rifare il join con `ldap_id_mapping = False`,
   popolando `uidNumber`/`gidNumber` su AD con `samba-tool` → l'altra strategia di
   mapping, collegata ai `posixAccount` di OpenLDAP.
2. **Automazione Ansible**: provisioning del DC come comando "incorniciato"
   (`when` + `changed_when`), join come `realm join` idempotente.
3. **Stabilità/produzione (futuro)**: dimensionamento RAM, NTP robusto,
   `systemd-resolved` disabilitato via cloud-init, secondo DC per ridondanza.

---

*Companion di `teoria_active_directory.md`. Tutto in rete locale, solo software
open-source. Dalla teoria LDAP a un dominio Active Directory funzionante, costruito
a mano e compreso pezzo per pezzo.*

# Approfondimento: attributi POSIX in AD + Troubleshooting SSSD

Runbook della sessione: passare il client AD dall'**ID mapping algoritmico** alla
lettura degli **attributi POSIX** (`uidNumber`/`gidNumber`) definiti in AD — per far
combaciare gli UID con quelli di OpenLDAP. Include il **percorso di troubleshooting
completo** (le piste sbagliate e la causa vera) e una guida al **debug di SSSD via
log**, usato qui per la prima volta.

Companion di `teoria_active_directory.md` e `pratica_active_directory.md`.

**Risultato finale:** `id mzelli@ad.lab.home` → `uid=10000 gid=10000(devops)`
(gli stessi numeri del mondo OpenLDAP).

---

## 1. Il concetto

Due strategie per tradurre il SID di AD in UID/GID Unix:

- **ID mapping algoritmico** (`ldap_id_mapping = True`, default del provider `ad`):
  SSSD calcola l'UID dal RID del SID. Zero amministrazione, numeri grandi.
- **Attributi POSIX** (`ldap_id_mapping = False`): SSSD legge `uidNumber`/`gidNumber`
  espliciti dagli oggetti AD (possibili grazie a `--use-rfc2307` al provisioning).
  Controlli i numeri, ma devi popolarli.

Due regole chiave (dai manuali SSSD):
- Quando l'ID mapping è **attivo**, `uidNumber`/`gidNumber` vengono **ignorati**.
  Quindi per usare i POSIX serve scrivere gli attributi **e** spegnere il mapping.
- Cambiare la strategia di mapping richiede di **azzerare la cache** di SSSD
  (non sa cambiare un ID a caldo).
- Con `ldap_id_mapping = False`, un utente **senza** `uidNumber`/`gidNumber` diventa
  **invisibile** su Linux. Anche il gruppo primario deve avere un `gidNumber`,
  altrimenti torna l'errore `cannot find name for group ID`.

---

## 2. La procedura (quella che funziona)

### Sul DC (`dc1`) — scrivere gli attributi POSIX

```bash
# il gruppo prende un GID
sudo samba-tool group edit devops
#   aggiungi:  gidNumber: 10000

# l'utente prende i suoi attributi POSIX (stessi valori di OpenLDAP)
sudo samba-tool user edit mzelli
#   aggiungi:
#     uidNumber: 10000
#     gidNumber: 10000            # gruppo primario = devops
#     unixHomeDirectory: /home/mzelli
#     loginShell: /bin/bash
```
`samba-tool ... edit` apre l'oggetto in formato **LDIF** nell'editor ($EDITOR=vim) —
lo stesso formato usato per slapd. Verifica:
```bash
sudo samba-tool user show mzelli | grep -iE 'uidNumber|gidNumber|unixHome|loginShell'
sudo samba-tool group show devops | grep -i gidNumber
```

### Sul client (`lb`) — spegnere l'ID mapping

> **PREREQUISITO scoperto a caro prezzo:** l'host deve conoscere il proprio **FQDN**
> (vedi Troubleshooting). Su `/etc/hosts`:
> ```
> 192.168.1.75   menu-lb.ad.lab.home   menu-lb
> ```
> `hostname -f` deve dare `menu-lb.ad.lab.home`.

In `/etc/sssd/sssd.conf`, sezione `[domain/ad.lab.home]`:
```ini
ldap_id_mapping = False
```
Poi azzerare **entrambe** le cache e riavviare:
```bash
sudo systemctl stop sssd
sudo rm -rf /var/lib/sss/db/* /var/lib/sss/mc/*
sudo systemctl start sssd
id mzelli@ad.lab.home        # -> uid=10000 gid=10000(devops)
su - mzelli@ad.lab.home      # home ora: /home/mzelli (da unixHomeDirectory)
```

---

## 3. TROUBLESHOOTING — il percorso completo (piste sbagliate incluse)

**Sintomo:** dopo aver messo `ldap_id_mapping = False`, `id mzelli@ad.lab.home`
restituiva ancora l'UID calcolato (`1494601103`) e `gid=domain users`, non `10000`.

Il metodo è stato **eliminazione per esclusione**: un sospetto alla volta, verificato
e scartato, finché i log non hanno dato la verità.

| # | Ipotesi | Verifica | Esito |
|---|---------|----------|-------|
| 1 | La riga `False` non è salvata | `grep -n ldap_id_mapping sssd.conf` | C'è, riga 17 → **scartata** |
| 2 | Cache `mc/` non svuotata | `rm -rf db/* mc/*` | Ancora vecchio UID → **scartata** |
| 3 | Riga nella sezione sbagliata (`[sssd]` invece di `[domain]`) | `grep -nE '^\[|ldap_id_mapping'` | È in `[domain/ad.lab.home]` → **scartata** |
| 4 | Override in `/etc/sssd/conf.d/` | `grep -rn ldap_id_mapping /etc/sssd/` | Nessun override → **scartata** |
| 5 | Permessi del file errati | `ls -l sssd.conf` | `0600 root:root` ok → **scartata** |
| 6 | Cache testarda / processo | `rm -rf` + reboot | Ancora vecchio → **scartata** |
| 7 | Ticket Kerberos scaduto (giorni passati) | l'`id` NON usa il ticket utente (usa il keytab di macchina) | concettualmente **scartata**, ma ha spinto a guardare il keytab |
| 8 | Rapporto Kerberos macchina rotto | `kinit -k 'MENU-LB$@...'` + `klist -k` | keytab valido, join sano → **scartata** |
| 9 | **FQDN mancante** | `hostname -f` dava `menu-lb` (non FQDN) | **Problema reale**, corretto |
| 10 | **Global Catalog senza attributi POSIX** | log del backend con debug 9 | **CAUSA VERA** (vedi sotto) |

### La causa vera (dai log)

Riga decisiva nel log del backend, allo startup di SSSD:
```
[ad_disable_gc] POSIX attributes were requested but are not present on the
server side. Global Catalog lookups will be disabled
```

**Spiegazione:** il provider `ad` di SSSD, per default, cerca gli attributi POSIX nel
**Global Catalog** (porta **3268**) — non nell'LDAP normale (389). Samba **non
pubblica** gli attributi POSIX nel Global Catalog di default. Quindi:
1. SSSD chiede `uidNumber`/`gidNumber` al GC → non li trova;
2. SSSD **disabilita da solo il Global Catalog** e ricade sull'LDAP standard (389);
3. sulla 389 gli attributi **ci sono** → legge `uidNumber: 10000`.

**Perché prima non scattava:** senza l'**FQDN** corretto (pista #9), le query di SSSD
verso il DC non andavano a buon fine, e SSSD restava bloccato sul mapping da SID
senza arrivare alla scoperta "GC vuoto → uso la 389". Corretto l'FQDN, al successivo
riavvio pulito la catena si è sbloccata: query ok → GC senza POSIX → fallback su 389
→ `uid=10000`. **Cause concatenate**: l'FQDN era il prerequisito, il GC il meccanismo.

> Nota: non è servita la riga `ad_enable_gc = False` (che forza l'uso della 389):
> SSSD l'ha fatto da solo (`ad_disable_gc`). Se mai servisse forzarlo a mano, è quella
> l'opzione, in `[domain/...]`.

### Lezioni di metodo

- **Eliminazione ordinata**: file → sezione → permessi → cache → join → keytab →
  FQDN → log. Una pista alla volta, verificata.
- **A un certo punto si smette di indovinare e si leggono i log.** La verità era lì,
  scritta (`ad_disable_gc`).
- Le cause reali sono spesso **concatenate** e non dove sembrano (qui: un hostname).
- L'errore visibile fin dall'inizio (`gid=domain users` invece di `devops`) era già
  un indizio: indicava che SSSD NON leggeva gli attributi dell'utente.

---

## 4. DEBUG DI SSSD — come si legge cosa fa il demone

Strumento nuovo di questa sessione. SSSD è "silenzioso" di default: per capire *perché*
fa qualcosa, si alza il livello di debug e si leggono i log.

### Dove sono i log
`/var/log/sssd/` — un file per componente:
| File | Contenuto |
|------|-----------|
| `sssd.log` | il monitor principale |
| `sssd_<dominio>.log` (es. `sssd_ad.lab.home.log`) | **il backend** — quello che conta: query al DC, mapping, attributi |
| `sssd_nss.log` | risoluzione identità (NSS) |
| `sssd_pam.log` | autenticazione (PAM) |

### I livelli di debug
Da **0** (solo errori critici) a **9** (tutto, verbosissimo). Si imposta:
- a runtime: `sudo sssctl debug-level 9` (e `... 0` per riabbassare);
- in modo persistente: `debug_level = 9` dentro una sezione di `sssd.conf`.

### Il workflow di debug
```bash
sudo sssctl debug-level 9          # alza il dettaglio
sudo systemctl restart sssd        # applica
sudo sss_cache -E                  # invalida la cache (forza query fresche)
id mzelli@ad.lab.home              # RIPRODUCI il problema
sudo tail -60 /var/log/sssd/sssd_ad.lab.home.log   # LEGGI il backend
sudo sssctl debug-level 0          # RIABBASSA (a 9 i log esplodono)
sudo systemctl restart sssd
```

### Come si legge una riga di log
```
(2026-06-23 18:20:57): [be[ad.lab.home]] [ad_disable_gc] (0x3f7c0): POSIX attributes...
   timestamp            componente       funzione        livello   messaggio
```
- `[be[...]]` = *back end* del dominio (il processo che parla col DC).
- `[nome_funzione]` = dove, nel codice, succede la cosa — utile per cercare la causa.
- `(0xNNNN)` = bitmask del livello; `0x0020`/`0x0040` sono messaggi di severità alta
  (errori/fallimenti) — sono quelli da cercare per primi.

### `sssctl` — il coltellino svizzero (pacchetto `sssd-tools`)
```bash
sudo sssctl config-check                 # valida sssd.conf (come 'netplan generate')
sudo sssctl user-checks mzelli@ad.lab.home   # risolve un utente bypassando cache
sudo sssctl domain-status ad.lab.home     # stato del dominio/connessione
sudo sssctl debug-level [0-9]             # livello di log a runtime
```

**Principio generale:** quando una config è corretta ma il comportamento non cambia,
**non indovinare — strumenta e osserva**. I log sono la fonte di verità.

---

## 5. Problema secondario (non bloccante): Dynamic DNS

Nei log comparivano ripetuti:
```
nsupdate child failed ... Dynamic DNS update failed
```
È SSSD che prova a registrare il proprio record DNS sul DC via update dinamico
(GSS-TSIG) e fallisce per permessi. **Non** tocca login né identità (`id`/`su`
funzionano). Si silenzia, se dà fastidio, con `dyndns_update = false` in
`[domain/ad.lab.home]`. Rifinitura, non urgenza.

---

## 6. Specchietto — sigle e termini di questa sessione

| Termine | Significato |
|---------|-------------|
| **ID mapping (algoritmico)** | SSSD calcola UID/GID dal SID (`ldap_id_mapping=True`). |
| **Attributi POSIX** | `uidNumber`/`gidNumber`/`unixHomeDirectory`/`loginShell` letti da AD (`ldap_id_mapping=False`). |
| **Global Catalog (GC)** | Indice a livello di foresta, porta **3268**. SSSD vi cerca i POSIX per default; Samba non ce li mette → fallback su 389. |
| **LDAP standard** | Porta **389**: l'oggetto completo, dove i POSIX *ci sono*. |
| **`ad_enable_gc`** | Opzione SSSD per (dis)abilitare l'uso del GC. SSSD può disabilitarlo da solo (`ad_disable_gc`). |
| **keytab** | `/etc/krb5.keytab`: chiavi della MACCHINA per autenticarsi al DC senza password. |
| **FQDN** | Nome completo (`menu-lb.ad.lab.home`); senza, AD non deduce il dominio della macchina. |
| **`sssctl`** | Tool di diagnostica di SSSD (config-check, user-checks, debug-level). |
| **debug_level** | Verbosità dei log SSSD, 0–9. |
| **dyndns** | Aggiornamento DNS dinamico del client verso il DC (qui fallisce, ma è secondario). |
| **cache SSSD** | `/var/lib/sss/db/` (su disco) + `/var/lib/sss/mc/` (memoria). Da azzerare quando si cambia l'ID mapping. |

---

## 7. Da qui

- **Automazione (Ansible)**: provisioning del DC + `realm join` idempotenti — l'ultimo
  pezzo per chiudere il ciclo manuale→codice anche per l'AD.
- **Rifiniture**: silenziare il dyndns; valutare `sudo` per un gruppo AD su `lb`.

---

*Companion di `teoria_active_directory.md` e `pratica_active_directory.md`. La sessione
di troubleshooting più formativa del percorso: si è passati dal "tentare soluzioni" al
"leggere i log", ed è lì che la causa (Global Catalog senza attributi POSIX, sbloccato
dall'FQDN) è venuta allo scoperto.*


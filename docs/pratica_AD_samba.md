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

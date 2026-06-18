# Teoria di Active Directory — companion di studio

Documento di riferimento per lo studio di Active Directory, costruito **a partire
dal modello LDAP** già padroneggiato. AD non è un mondo nuovo da zero: è il modello
LDAP + alcuni strati sopra. Ogni concetto è agganciato a uno già noto.

---

## 0. L'idea di fondo

Al suo cuore, un domain controller AD **parla LDAP**: ha un DIT, oggetti con
objectClass, un base DN, risponde su 389/636. La differenza è tutto ciò che AD
costruisce *attorno* a quel nucleo.

**Metafora:** quello che hai costruito è un ottimo *schedario condiviso* (utenti,
gruppi, appartenenze). AD prende quello schedario e aggiunge una *portineria*, un
*sistema di pass*, e un *regolamento aziendale applicato in automatico*.

I tre pilastri che AD aggiunge: **Kerberos** (autenticazione a ticket), **DNS**
(service discovery), **oggetto unificato con SID** (fusione dei mondi POSIX/directory).

---

## 1. Kerberos — dal "bind ogni volta" al ticket

### Gli attori
- **Client** (l'utente/macchina).
- **KDC** (*Key Distribution Center*): il "quartier generale", gira sul DC. Ha due
  sportelli: **AS** (*Authentication Service*, l'ingresso) e **TGS** (*Ticket
  Granting Service*, l'info-point dei pass).
- **Servizio** (file server, mail, ecc.).

Vocabolario: **realm** = equivalente del dominio, in MAIUSCOLO (`LAB.HOME`).
**Principal** = identità (`mzelli@LAB.HOME`; `host/srv.lab.home@LAB.HOME` per i servizi).

### Metafora: il braccialetto del festival
- Mostri il documento **una volta** all'ingresso e ricevi un **braccialetto** (TGT).
- Col braccialetto ottieni i **pass per i singoli palchi** (service ticket).
- Al palco mostri il pass; lo staff non vede mai il tuo documento.

### Il flusso in tre scambi
1. **AS (ingresso).** Il client prova la sua identità **senza mandare la password**:
   invia un timestamp cifrato con una chiave derivata dalla password (pre-auth). Il
   KDC, che ha la stessa chiave, decifra: se l'orario è valido e recente, identità
   provata. Restituisce il **TGT**, cifrato con la chiave segreta del KDC → il client
   lo porta ma non può leggerlo né falsificarlo (sigillo a prova di manomissione).
2. **TGS (richiesta pass).** Il client mostra il TGT e chiede un servizio X. Il TGS
   verifica il TGT (l'ha cifrato lui) ed emette un **service ticket** per X, cifrato
   con la chiave segreta di X.
3. **AP (accesso).** Il client mostra il service ticket a X. X lo decifra con la
   propria chiave (per questo si fida), vede chi è il client, concede l'accesso. X
   non ha mai visto la password né contattato il KDC.

### Perché vale la pena
- **SSO (Single Sign-On)**: una sola verifica della password (all'ingresso), poi
  ticket riutilizzabili tutto il giorno. Nel mondo LDAP, invece, ogni accesso era un
  bind con verifica della password.
- I servizi non custodiscono password: si fidano di ticket firmati → meno segreti
  sparsi, meno superficie d'attacco.
- Possibile la **mutua autenticazione**: anche il client può verificare il servizio
  (niente server impostori).

### Il prezzo
- **Tempo**: ticket e timestamp hanno finestre strette (default ~5 min di scarto
  massimo). Clock sballato → autenticazione fallita. **NTP non è opzionale.**
  *(Metafora: il braccialetto scade; se il tuo orologio è sbagliato, litighi col
  buttafuori.)*
- **DNS**: serve per trovare il KDC (vedi pilastro DNS).

### Vederlo in pratica
```bash
kinit mzelli@LAB.HOME     # ottieni un TGT
klist                     # elenca i ticket (vedrai krbtgt/LAB.HOME + i service ticket)
kdestroy                  # cancella i ticket
```

### Keytab
Servizi e computer (che non "digitano" password) custodiscono la loro chiave in un
file **keytab** e lo usano per ottenere il proprio TGT in automatico. Anche le
**macchine** hanno un'identità Kerberos.

---

## 2. SID — l'identità immutabile per la sicurezza

Versione potenziata e generalizzata dell'`uidNumber` che già conosci.

### Cos'è
**Security Identifier**: identificatore **univoco e immutabile** di ogni *security
principal* (utente, gruppo, **computer**). È il vero "chi sei" per la sicurezza.

### Struttura (es. `S-1-5-21-3623811015-3361044348-30300820-1013`)
- `S` → è un SID
- `1` → revisione
- `5` → autorità emittente (5 = NT Authority)
- `21` → SID emesso da un dominio
- `3623811015-3361044348-30300820` → **identificatore del dominio** (unico, generato
  alla creazione del dominio)
- `1013` → **RID** (*Relative Identifier*), unico dentro il dominio, per il singolo
  principal

Prima parte = "di quale dominio sei", ultima = "quale membro sei".

### Perché SID e non il nome
I nomi cambiano (rinomina, matrimonio, refuso); i SID no. I permessi sulle risorse
(ACL) fanno riferimento al **SID**. Quindi rinominare un utente ne **preserva tutti
gli accessi**. *Metafora: il SID è il codice fiscale — il nome sui documenti cambia,
il codice che ti lega ai tuoi dati resta.*

### A runtime: l'access token
Al login il sistema costruisce un **token** con il tuo SID + i SID di tutti i tuoi
gruppi. Ogni controllo d'accesso confronta i SID autorizzati sulla risorsa con quelli
nel token. È il meccanismo "appartenenza → autorizzazione" (come `devops`),
generalizzato.

### SID well-known
Alcuni sono costanti ovunque: *Domain Admins* = `<SID-dominio>-512`; *Everyone* =
`S-1-1-0`. *Metafora: come i numeri d'emergenza, stesso significato ovunque.*

### Il ponte verso Linux (SID → UID/GID) — rilevante per SSSD
Linux usa UID/GID numerici, AD usa SID. Quando una macchina Linux entra in AD, SSSD
deve tradurre. Due strategie (`ldap_id_mapping`):
- **ID mapping algoritmico**: SSSD calcola deterministicamente l'UID dal SID. Nessun
  attributo da gestire; coerente tra macchine se configurate uguali.
- **Attributi POSIX**: AD memorizza `uidNumber`/`gidNumber` espliciti (gli stessi
  `posixAccount` creati a mano!), SSSD li legge. Più controllo; utile in ambienti
  misti.

È il punto in cui il SID di AD e il `posixAccount` di LDAP si incontrano.

### RID pool e FSMO
Ogni DC riceve un *pool* di RID da assegnare, gestito dal ruolo **RID Master**
(uno dei ruoli FSMO), così DC diversi non assegnano lo stesso RID.

---

## 3. SSSD — ripreso, e cosa cambia con AD

SSSD è il **mediatore** tra l'OS (NSS = "chi è l'utente?"; PAM = "password giusta?
può entrare?") e la directory, con cache per il login offline. Lo conosci già con
`id_provider = ldap`. Con AD cambia il *provider*, e SSSD gestisce i pilastri in
automatico.

| Aspetto | `id_provider = ldap` (fatto a mano) | `id_provider = ad` |
|---|---|---|
| Autenticazione | bind LDAP | **Kerberos** automatico (TGT) |
| Trovare il server | `ldap_uri` + `/etc/hosts` | **DNS SRV** automatico |
| Fiducia TLS | `ldap_tls_cacert` a mano | gestita dal flusso AD/Kerberos |
| SID → UID | non serviva (posixAccount) | **ID mapping** o POSIX (`ldap_id_mapping`) |
| Accesso per gruppo | `access_provider = simple` + `simple_allow_groups` | **identico** |
| Cache offline, mkhomedir | come configurato | **identico** |

Il modello mentale si trasferisce di peso. In AD il `sssd.conf` si semplifica anche
(niente `ldap_uri`/`/etc/hosts`/percorso CA: lo fanno Kerberos e DNS). L'unione al
dominio non si scrive a mano: **`realm join`** (realmd) o **`adcli`** creano
l'account-computer, generano il keytab e scrivono il `sssd.conf`.

Sul client: `realm list`, `id mzelli@lab.home`, `kinit`/`klist`.

---

## 4. Struttura logica di AD

- **Dominio**: il tuo base DN (`dc=lab,dc=home` ↔ `lab.home`), ma come **confine
  amministrativo e di sicurezza**.
- **Domain Controller (DC)**: come `slapd`, ma fa anche da **KDC Kerberos** e spesso
  **DNS**. Replica **multi-master** (ogni DC scrive; le modifiche si sincronizzano) —
  non master/slave. *Metafora: documento collaborativo condiviso, non original +
  fotocopie.*
- **Foresta / albero**: più domini formano un albero (spazio DNS condiviso); più
  alberi una **foresta** = confine di sicurezza ultimo (schema condiviso).
  *Metafora: confederazione (foresta) di stati membri (domini) sotto una costituzione
  comune.*
- **OU (Organizational Unit)**: il tuo contenitore `ou`, con due superpoteri:
  **delega amministrativa** e applicazione delle **Group Policy**.

### Group Policy (lo strato che LDAP non ha)
Le **GPO** sono regole di configurazione che il dominio **applica automaticamente** a
utenti/computer di un'OU (software, restrizioni, policy password, ecc.), enforced di
continuo dai client. *Metafora: il regolamento dell'edificio che si applica da solo,
senza un tecnico stanza per stanza.* Cugino concettuale di Ansible, ma integrato nel
dominio.

### Meccanismi dietro le quinte (cultura, non da memorizzare)
- **FSMO**: in multi-master, alcune operazioni le fa **un solo DC arbitro** per ruolo
  (es. assegnare RID, modificare lo schema). *Metafora: l'ufficio unico che assegna i
  numeri di matricola, per evitare doppioni.*
- **Global Catalog**: indice parziale a livello di foresta per ricerche veloci tra
  tutti i domini. *Metafora: l'indice analitico di un'enciclopedia in più volumi.*
- **Trust**: relazioni di fiducia tra domini/foreste.

---

## 5. Dizionario di traduzione LDAP → AD

| LDAP (quello che conosci) | Active Directory |
|---|---|
| base DN `dc=lab,dc=home` | il **dominio** `lab.home` |
| il DIT / database | database AD (NTDS.dit) |
| entry | **oggetto** |
| objectClass / schema | schema AD (esteso: SID, account computer) |
| `ou` (contenitore) | **OU** (+ delega + GPO) |
| `posixAccount` + `posixGroup` + `groupOfNames` | **unico oggetto** utente/gruppo con **SID** |
| bind (a ogni accesso) | **Kerberos** (ticket + SSO) |
| `slapd` (un master) | **Domain Controller** (multi-master) |
| replica master→slave | **replica multi-master** |
| ACL su DN/attributi | ACL su **SID** |
| `/etc/hosts` a mano | **DNS** con record **SRV** |
| *(non esiste)* | **Group Policy** |
| SSSD sul client | **SSSD** (lo stesso) o domain-join nativo |

---

## 6. Strategia pratica (rispettando i vincoli: locale, open-source)

**Strumento:** **Samba AD DC** — un domain controller AD-compatibile, open-source,
su una VM del lab libvirt.

**Manuale prima, poi Ansible — ma con ritmo diverso da LDAP:**
- Il **DC** non si costruisce incrementalmente: si **provisiona in un colpo**
  (`samba-tool domain provision` tira su LDAP + Kerberos + DNS + SYSVOL). Per Samba
  **non ci sono moduli Ansible puliti** come `community.general.ldap_*`:
  l'automazione del DC sarà più *wrapping idempotente* di comandi `samba-tool` con il
  pattern `when` + `changed_when`.
- La **gestione oggetti** (`samba-tool user create`, `group addmembers`) è
  incrementale e si presta al "a mano poi Ansible".
- Il **client** (unione al dominio con `realm join` + SSSD) è il pezzo più adatto al
  manuale-prima, e trasferisce direttamente la competenza SSSD.

**Valore del manuale per AD:** non tanto *costruire* (come per slapd), ma **vedere i
concetti in azione** — provisionare e ispezionare cosa è stato creato, `kinit`/`klist`
per i ticket, ispezionare un SID, unire un client e guardare SSSD lavorare. Poi
automatizzare sapendo *perché*.

---

*Companion da affiancare al documento `percorso_ldap_riepilogo.md`. La regola resta:
teoria e "grammatica" prima, pratica poi — un concetto nuovo alla volta.*

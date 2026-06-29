# Infrastruttura Lab: Active Directory, Bastion & Hardening
### Documento riepilogativo dei progetti `terraform_exercise` + `ansible_ubuntu_docker_menu`

> Un lab completo "Infrastructure as Code" che costruisce, da zero e in modo riproducibile,
> una rete di VM Linux con autenticazione centralizzata (Active Directory via Samba),
> accesso protetto da un bastion host con Single Sign-On, firewall in lockdown, e uno
> stack applicativo containerizzato. Tutto versionato in Git, niente passi manuali.

---

## 1. Riassunto in due minuti

Hai costruito un **datacenter in miniatura** sul tuo PC, interamente descritto da codice. Due strumenti si dividono il lavoro:

- **Terraform/OpenTofu** crea le **macchine** (VM KVM/libvirt da immagine cloud Ubuntu): definisce hardware, rete, IP, e l'inizializzazione di primo avvio (cloud-init). È il "muratore" che tira su le scatole vuote.
- **Ansible** *configura* ciò che gira **dentro** le macchine: le unisce al dominio, installa i servizi, applica il firewall, fa il deploy dell'app. È l'"arredatore" che rende le scatole funzionali.

Il cuore concettuale del progetto è l'**identità centralizzata**: invece di gestire utenti e password su ogni macchina, c'è **un Domain Controller** (Active Directory implementato con Samba) che fa da unica fonte di verità per utenti, gruppi, DNS e autenticazione (Kerberos). Tutte le altre macchine si "uniscono al dominio" e si fidano del DC.

Sopra a questo, hai costruito la **sicurezza degli accessi**: un solo punto d'ingresso (il **bastion host**), un **firewall** che blocca tutto tranne il traffico necessario, e il **Single Sign-On Kerberos** che ti permette di saltare da una macchina all'altra senza mai ridigitare la password.

L'ultimo grande traguardo è stato **automatizzare anche il Domain Controller** (l'unico pezzo che prima era fatto a mano): ora anche la "fonte di verità" può essere ricostruita da codice in caso di disastro.

---

## 2. Le macchine del lab (chi è chi)

| VM (Terraform) | Hostname | IP | Ruolo |
|---|---|---|---|
| `dc` | `dc1` | .77 | **Domain Controller** — AD, DNS, Kerberos. La fonte di verità. |
| `bastion` | `bastion` | .78 | **Bastion host** — l'unica porta d'ingresso SSH dall'esterno. |
| `lb` | `menu-lb` | .75 | **Load balancer** (HAProxy) — distribuisce il traffico all'app. |
| `app` | `menu-app` | .72 | **App server** — FastAPI in container Docker. |
| `db` | `menu-db` | .73 | **Database** — MySQL in container Docker. |
| `app2` | `menu-app-2` | .74 | *(parcheggiata: secondo nodo app, per RAM)* |
| `ldap` | — | .76 | *(ramo OpenLDAP di studio, congelato)* |

Tutte su rete **bridge** (LAN 192.168.1.0/24, gateway .1). Il DC usa più RAM (2 GiB) perché regge servizi critici; gli altri 1 GiB.

---

## 3. Schema dell'architettura

```
                          INTERNET / LAN ESTERNA
                                   │
                                   │  (solo SSH, porta 22)
                                   ▼
                        ┌────────────────────┐
                        │   BASTION (.78)     │   ← unico ingresso
                        │  firewall: SSH only │     "salto" obbligato
                        └─────────┬──────────┘
                                  │  ProxyJump + SSO Kerberos
              ┌───────────────────┼───────────────────┐
              │                   │                   │
              ▼                   ▼                   ▼
     ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
     │   LB (.75)   │   │  APP (.72)   │   │   DB (.73)   │
     │   HAProxy    │──▶│   FastAPI    │──▶│   MySQL      │
     │  :80 :8080   │   │  (Docker)    │   │  (Docker)    │
     └──────┬───────┘   └──────┬───────┘   └──────┬───────┘
            │                  │                  │
            └──────────────────┼──────────────────┘
                               │  ogni nodo è "membro" del dominio:
                               │  chiede al DC chi sei (Kerberos/LDAP)
                               ▼
                        ┌────────────────────┐
                        │     DC1 (.77)       │
                        │  Active Directory   │
                        │  Samba:             │
                        │   • DNS  (:53)      │
                        │   • Kerberos (:88)  │
                        │   • LDAP (:389)     │
                        │  = fonte di verità  │
                        └────────────────────┘

   ── Il firewall su OGNI nodo-servizio: nega tutto in ingresso,
      tranne SSH dal solo bastion + le porte del proprio servizio.
```

---

## 4. Mappa concettuale: come si collegano i pezzi

```
                        IDENTITÀ CENTRALIZZATA
                                 │
            ┌────────────────────┴────────────────────┐
            │                                          │
   DOMAIN CONTROLLER (Samba AD)              I MEMBRI DEL DOMINIO
   "chi sei? a cosa hai diritto?"            "mi fido del DC per saperlo"
            │                                          │
   ┌────────┼────────┐                      ┌──────────┼──────────┐
   │        │        │                      │          │          │
  DNS    KERBEROS  LDAP                  realmd/    login AD    SSO via
 (nomi) (ticket)  (utenti)               SSSD      (gruppo     Kerberos
   │        │        │                  (il join)   devops)    (GSSAPI)
   │        │        │                      │          │          │
   └────────┴────────┘                      └──────────┴──────────┘
        il DC EROGA                              i CLIENT CONSUMANO
                                                      │
                                                      ▼
                                          ACCESSO SICURO (a strati)
                                                      │
                   ┌──────────────────────────────────┼──────────────────┐
                   │                                   │                  │
              BASTION HOST                         FIREWALL            SSO/ProxyJump
         "unico punto d'ingresso"            "nega tutto tranne     "un login, salto
                   │                          il necessario"          ovunque"
                   │                                   │                  │
                   └───────────────────────────────────┴──────────────────┘
                                         │
                                         ▼
                              INFRASTRUTTURA AS CODE
                       (Terraform crea · Ansible configura · Git versiona)
                                         │
                                         ▼
                              STACK APPLICATIVO (menu)
                        HAProxy → FastAPI → MySQL (in Docker)
```

**La logica del collegamento:** l'identità centralizzata (DC) è la fondazione. I membri si fidano del DC per sapere "chi sei". Su questa fiducia si appoggia l'accesso sicuro (bastion + firewall + SSO). Tutto è costruito come codice. E in cima gira l'applicazione vera.

---

## 5. I filoni del progetto, in ordine di costruzione

### Filone 0 — Le fondamenta (la parte iniziale)
VM con Terraform da immagine cloud Ubuntu + cloud-init (utente `ubuntu`, chiave SSH, IP statici via netplan). Stack app già containerizzato: FastAPI e MySQL in Docker, HAProxy come load balancer. Questa era la base "macchine + app" prima dell'identità e della sicurezza.

### Filone 1 — Il Domain Controller (la fonte di verità)
Un DC **Active Directory** implementato con **Samba** (`server role = active directory domain controller`). Eroga tre servizi fondamentali: **DNS** (i nomi `*.ad.lab.home`), **Kerberos** (i ticket di autenticazione), **LDAP** (la directory di utenti e gruppi). Realm `AD.LAB.HOME`, utente `mzelli` nel gruppo `devops`.

### Filone 2 — I client del dominio (ruolo `ad_client`)
Ogni nodo (bastion, lb, app, db) si **unisce al dominio** con `realmd` + `SSSD`. Punti chiave del ruolo:
- **Join idempotente**: controlla se è già membro prima di unirsi.
- **ID mapping** (`ldap_id_mapping=true`): assegna in modo coerente gli UID/GID agli utenti AD.
- **Login ristretto**: solo i membri del gruppo `devops` possono autenticarsi (privilegio minimo).
- **Differenza di design voluta**: bastion permette il login AD con password; i nodi-servizio (lb/app/db) hanno `ad_client_ssh_login_group: ""` → niente login umano con password, solo chiave + SSO. (Scelta didattica per confrontare i due approcci.)

### Filone 3 — Il bastion + Single Sign-On (ruolo `bastion`)
Il **bastion** è l'unico ingresso. Da lì, grazie al **SSO Kerberos (GSSAPI)**, salti sui nodi interni **senza ridigitare credenziali**: il ticket Kerberos ottenuto al bastion vale per tutto il dominio. Configurato con `ProxyJump` nel client SSH + il plugin `localauth` di SSSD che mappa i principal Kerberos agli utenti locali. Flusso quotidiano: `ssh bastion-ad` → `ssh menu-app.ad.lab.home` (zero password).

### Filone 4 — Il firewall in lockdown (ruolo `firewall`)
Strategia **"nega tutto, poi apri il minimo"**:
- Default: **deny** in ingresso, allow in uscita.
- Apre SSH **solo dal bastion** (`firewall_bastion_ip`).
- Apre solo le **porte di servizio** dichiarate da ogni nodo (es. lb apre 80/8080).
- **Lockdown a due tempi** (anti-lockout): Tempo 1 lascia un "paracadute" SSH dal tuo PC admin; Tempo 2 lo rimuove e chiude tutto. Così non rischi di tagliarti fuori da sola.

### Filone 5 — Automazione del DC (ruolo `domain_controller`)
L'ultimo buco IaC chiuso: il DC, prima provisionato a mano, ora è **codice**. Il ruolo, da una VM vergine: installa Samba, ferma i servizi in conflitto, **provisiona il dominio** (idempotente: salta se già esiste), configura krb5/DNS/forwarder, popola utenti e gruppi. Testato a fondo su un dominio finto usa-e-getta (`TEST.LOCAL`). Ora il DC è ricostruibile in caso di disastro.

### Filone 6 — Coerenza e mantenibilità (refactoring)
Pulizia strutturale: variabili al posto giusto (gruppo `menu_stack` per lo stack, `defaults/` dei ruoli col prefisso, vault per gruppo), rimozione di codice morto, playbook mirati ai gruppi giusti, separazione del ramo LDAP su un branch dedicato, e un playbook `reset_host_keys` per gestire le chiavi SSH alla ricreazione delle VM.

---

# PARTE TEORICA — I concetti che hai implementato

## A. Active Directory & il Domain Controller

**Il problema che risolve:** senza un'identità centralizzata, ogni macchina ha i suoi utenti e password. 10 macchine = 10 database di utenti da tenere allineati. Un incubo.

**La soluzione:** un **Domain Controller (DC)** fa da **unica fonte di verità**. Definisci l'utente *una volta* sul DC, e *tutte* le macchine "membri del dominio" lo riconoscono. Cambi la password una volta, vale ovunque. Active Directory è l'implementazione Microsoft di questo concetto; **Samba** ne è l'implementazione open-source compatibile, che hai usato.

**Cosa eroga un DC AD (tre servizi in uno):**
1. **DNS** — traduce i nomi (`menu-app.ad.lab.home`) in IP. In AD il DNS è *fondamentale*: i client trovano il DC stesso interrogando il DNS. Per questo un DNS rotto rompe tutto il dominio.
2. **Kerberos** — il sistema di autenticazione a ticket (vedi sotto).
3. **LDAP** — il "database" gerarchico di utenti, gruppi, computer. È la rubrica del dominio.

**Membro del dominio (domain join):** una macchina che "si fida" del DC. Quando un utente prova a loggarsi, la macchina non controlla un file locale: chiede al DC "questo utente esiste? la password è giusta? a quali gruppi appartiene?". Su Linux questo dialogo lo gestisce **SSSD** (System Security Services Daemon), configurato dal join di **realmd**.

---

## B. Kerberos (l'autenticazione a ticket)

**L'idea geniale:** dimostrare chi sei *senza* mandare la password in giro per la rete ogni volta.

**Analogia del parco divertimenti:**
1. All'ingresso mostri la carta d'identità (la tua password) **una sola volta** e ricevi un **braccialetto** (il *Ticket Granting Ticket*, TGT). Questo avviene quando fai `kinit` o il login.
2. Per ogni giostra (ogni servizio: SSH, un file server...), mostri il braccialetto a una **biglietteria** (il KDC, Key Distribution Center, che gira sul DC) e ricevi un **biglietto specifico** per quella giostra (un *service ticket*).
3. Il gestore della giostra controlla il biglietto e ti fa entrare. **Non ha mai visto la tua carta d'identità.**

**Perché è sicuro:** la password viaggia (cifrata) una volta sola. Dopo, girano solo ticket a tempo, che scadono. Se qualcuno intercetta un ticket, è inutile dopo poche ore.

**Cos'è il "realm":** il dominio Kerberos, scritto in MAIUSCOLO per convenzione (`AD.LAB.HOME`). Identifica "di quale regno fai parte".

**Come abilita il tuo SSO:** ottieni il TGT al bastion (login). Quando salti su `menu-app`, SSH usa **GSSAPI** per presentare automaticamente un service ticket Kerberos al nodo. Il nodo lo verifica col DC → ti fa entrare **senza chiederti la password**. Questo è il Single Sign-On.

---

## C. Il Bastion Host (il punto d'ingresso unico)

**Il problema:** se ogni macchina è raggiungibile via SSH dall'esterno, hai 5 porte da difendere, 5 superfici d'attacco.

**La soluzione:** **un solo** host esposto (il bastion), rinforzato e sorvegliato. Tutto il resto è raggiungibile *solo* passando da lì. Riduci la superficie d'attacco da 5 porte a 1.

**ProxyJump:** il meccanismo SSH per "saltare" attraverso il bastion verso una macchina interna in un comando solo. SSH apre una connessione al bastion e, attraverso di essa, una seconda connessione al nodo finale. Per te è trasparente: scrivi `ssh menu-app` e il salto avviene dietro le quinte.

**Perché si combina col SSO:** il bastion da solo ti farebbe ridigitare la password sul nodo finale. Con Kerberos, il ticket ottenuto al bastion vale ovunque → salti senza credenziali. Bastion (sicurezza del perimetro) + Kerberos (comodità senza sacrificare sicurezza) = la coppia vincente.

---

## D. Il Firewall (ufw) e la difesa a strati

**Principio del "default deny":** la regola d'oro. Parti negando **tutto** il traffico in ingresso, poi apri **solo** ciò che serve esplicitamente. L'opposto ("permetti tutto, blocca le minacce note") è perdente: non puoi conoscere tutte le minacce.

**Cosa apri nel tuo lab:**
- SSH **solo dall'IP del bastion** (non da chiunque).
- Le porte del servizio specifico di ogni nodo (es. 80/8080 su lb), e solo quelle.

**Anti-lockout (il lockdown a due tempi):** il rischio del default-deny è chiudere SSH e tagliarti fuori da sola. La tua soluzione:
- **Tempo 1:** applichi le regole MA lasci un "paracadute" — SSH aperto anche dal tuo IP admin. Verifichi che tutto funzioni.
- **Tempo 2:** rimuovi il paracadute. Ora vale solo l'accesso dal bastion. Lockdown completo, ma sei sicura che funziona perché l'hai testato col paracadute ancora attivo.

**Difesa a strati (defense in depth):** la sicurezza non è un muro solo, ma cipolla di strati. Anche se uno cade, gli altri reggono:
1. **Firewall** — solo il bastion può bussare via SSH.
2. **Bastion** — unico ingresso, rinforzato.
3. **Autenticazione AD** — solo utenti del dominio.
4. **Autorizzazione di gruppo** — solo i membri di `devops`.
5. **Chiavi SSH** invece di password sui nodi-servizio.

---

## E. Infrastructure as Code (la filosofia di fondo)

**Cosa significa:** l'infrastruttura non è fatta a mano cliccando, ma **descritta in file di testo** versionati in Git. Il vantaggio: riproducibilità (la ricrei identica), tracciabilità (Git racconta ogni cambiamento), e niente "ha funzionato sul mio PC e nessuno sa perché".

**Terraform vs Ansible (la divisione del lavoro):**
- **Terraform/OpenTofu** = *provisioning*: crea/distrugge le **risorse** (VM, dischi, reti). Mantiene uno *state* che sa cosa esiste. È **dichiarativo**: descrivi lo stato finale, lui calcola le differenze.
- **Ansible** = *configuration management*: configura ciò che è **dentro** le macchine (pacchetti, servizi, file). È **idempotente**: lo rilanci e converge sempre allo stesso stato.

**Idempotenza (il concetto chiave di Ansible):** un'operazione che, rieseguita, dà sempre lo stesso risultato senza effetti collaterali. Lanci il playbook 10 volte → la macchina finisce sempre nello stesso stato corretto. Per i comandi che *non* sono idempotenti di natura (come `samba-tool domain provision`), lo diventano con il pattern **"controlla-poi-agisci"**: prima verifichi se la cosa esiste già, e agisci solo se serve.

**cloud-init:** il meccanismo che configura una VM **al primo avvio** (utente, chiavi SSH, rete). Gira *una sola volta*. Per questo le modifiche successive vanno fatte con Ansible: cloud-init non "ri-configura" una VM già avviata.

---

## F. Glossario rapido

| Termine | In una riga |
|---|---|
| **Domain Controller (DC)** | Il server che custodisce l'identità del dominio (utenti, gruppi, autenticazione). |
| **Active Directory / Samba** | Il sistema di identità centralizzata (Samba = versione open-source). |
| **Realm** | Il "regno" Kerberos/AD (es. `AD.LAB.HOME`). |
| **Kerberos / TGT / KDC** | Autenticazione a ticket: il braccialetto (TGT) dalla biglietteria (KDC). |
| **SSSD / realmd** | I demoni Linux che uniscono la macchina al dominio e parlano col DC. |
| **GSSAPI** | Il "linguaggio" con cui SSH usa Kerberos per il SSO. |
| **Bastion host** | L'unico punto d'ingresso SSH, rinforzato. |
| **ProxyJump** | Il salto SSH attraverso il bastion verso i nodi interni. |
| **Default deny** | Firewall: nega tutto, apri solo il necessario. |
| **Idempotenza** | Rieseguire un'operazione dà sempre lo stesso risultato. |
| **IaC** | Infrastruttura descritta come codice versionato, non a mano. |

---

*Documento generato come riepilogo del lavoro sui progetti `terraform_exercise` e `ansible_ubuntu_docker_menu`.*

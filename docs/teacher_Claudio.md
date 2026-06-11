# Percorso LDAP → fondamenta di Active Directory

Documento di riepilogo del percorso di studio LDAP: dalla teoria, alla pratica
manuale, fino all'implementazione completa come codice (Ansible) di un sistema di
identità centralizzata.

**Vincoli rispettati:** tutto in rete locale, solo software open-source.
**Stack:** OpenLDAP (slapd 2.6.x) su Ubuntu 24.04, VM via Terraform/OpenTofu
(libvirt/KVM), automazione con Ansible, client con SSSD.

---

## Indice

1. Teoria LDAP
2. Fase manuale (runbook dei comandi)
3. TLS: teoria e pratica
4. Come LDAP viene "consumato" (NSS / PAM / SSSD)
5. Automazione: ruolo `ldap_server`
6. Automazione: ruolo `ldap_client`
7. Lezioni DevOps trasversali
8. Gotcha incontrati e soluzioni
9. Comandi di verifica
10. Cosa resta da fare

---

## 1. Teoria LDAP

**Cos'è.** LDAP (*Lightweight Directory Access Protocol*) è un **protocollo**
client-server (non un prodotto) per accedere a un *directory service*. Versione
LDAPv3 (RFC 4510–4519). Porte: **389** (in chiaro / StartTLS), **636** (LDAPS).
OpenLDAP (`slapd`) è *un'implementazione*; Active Directory è un'altra.

**Perché non un DB relazionale.** Una directory è ottimizzata per
**letture frequenti, scritture rare, dati gerarchici** interrogati per attributo.
Niente JOIN/transazioni complesse; in cambio, letture velocissime e struttura ad
albero nativa. È il motivo per cui l'autenticazione centralizzata usa LDAP.

**Il modello: il DIT** (*Directory Information Tree*), albero gerarchico di entry.

```
dc=lab,dc=home            <- radice (base DN / suffix)
├── ou=people
│   └── uid=mzelli        <- entry utente
└── ou=groups
    └── cn=devops
```

### Vocabolario

- **Entry**: un nodo dell'albero.
- **DN** (*Distinguished Name*): percorso assoluto univoco, es.
  `uid=mzelli,ou=people,dc=lab,dc=home`. Si legge **da sinistra (foglia) a destra
  (radice)** — opposto di un path Unix.
- **RDN**: il pezzo più a sinistra del DN (`uid=mzelli`).
- **Attributo**: coppia chiave→valore; può essere multi-valore.
- **objectClass**: dichiara il *tipo* di entry e quindi quali attributi sono
  obbligatori (**MUST**) e permessi (**MAY**). È il "contratto" della entry.
- **Schema**: il regolamento del server (quali classi/attributi esistono). Il
  server **rifiuta** entry che lo violano — come un compilatore con tipi forti.
- **Prefissi naming**: `dc`=domain component, `ou`=organizational unit (contenitore),
  `cn`=common name, `uid`=user id.

### Ereditarietà degli objectClass

Le classi formano una catena via l'attributo **`SUP`** (superior), e MUST/MAY si
ereditano lungo di essa:

```
inetOrgPerson → organizationalPerson → person → top
                                       MUST: sn, cn   <- l'obbligo viene da qui
```

Per questo creando un `inetOrgPerson` serve `sn`: lo eredita da `person`.

### Operazioni (i "verbi")

- **bind**: autenticarsi. Modalità: *anonima*, *simple bind* (DN+password),
  *SASL* (es. EXTERNAL via socket).
- **search**: base DN + **scope** + filtro + attributi.
  - scope: `base` (solo la entry), `one` (figli diretti), `sub` (tutto il sottoalbero, default).
- **add / modify / delete / modrdn**: creare / modificare / cancellare / rinominare.

### Filtri (RFC 4515)

- `(uid=mzelli)` — uguaglianza
- `(&(objectClass=inetOrgPerson)(mail=*))` — AND
- `(|(uid=a)(uid=b))` — OR
- `(!(uid=admin))` — NOT

### LDIF

Formato testuale per entry e modifiche. Entry separate da **riga vuota**.

```ldif
dn: uid=mzelli,ou=people,dc=lab,dc=home
objectClass: inetOrgPerson
uid: mzelli
cn: Martina Zelli
sn: Zelli
```

Per le **modifiche**, sintassi con `changetype`:

```ldif
dn: uid=mzelli,ou=people,dc=lab,dc=home
changetype: modify
replace: userPassword
userPassword: {SSHA}...
```

(Il trattino `-` su riga singola separa più operazioni sulla stessa entry.)

### I due alberi amministrativi

| | albero dati | albero config |
|---|---|---|
| DN radice | `dc=lab,dc=home` | `cn=config` |
| autenticazione | simple bind (`-x -D ... -W`) | SASL EXTERNAL (`-Y EXTERNAL -H ldapi:///`) |
| identità | `cn=admin` + password | utente **root del SO** (via `sudo`) |

---

## 2. Fase manuale (runbook dei comandi)

> Nota: tutti i comandi vanno eseguiti **sulla VM Ubuntu**, non sul PC Arch.

### Installazione e base DN

```bash
sudo apt update
sudo apt install -y slapd ldap-utils      # slapd = server; ldap-utils = client CLI
sudo dpkg-reconfigure slapd               # imposta dominio -> base DN dc=lab,dc=home, backend MDB
```

La password chiesta è quella dell'**admin LDAP** (`cn=admin,dc=lab,dc=home`),
distinta da SSH / utente di sistema / sudo. Serve a ogni *scrittura*.

### Verifica e ispezione

```bash
systemctl status slapd
ss -tlnp | grep 389
ldapsearch -x -LLL -H ldap://localhost -b "dc=lab,dc=home"      # bind anonimo
sudo slapcat                                                    # legge il DB su disco (mostra i metadati operazionali)
```

`ldapsearch` parla via rete e rispetta le ACL; `slapcat` legge il DB grezzo.

### Struttura e utenti

```ldif
# 01-struttura.ldif
dn: ou=people,dc=lab,dc=home
objectClass: organizationalUnit
ou: people

dn: ou=groups,dc=lab,dc=home
objectClass: organizationalUnit
ou: groups
```

```bash
ldapadd -x -D "cn=admin,dc=lab,dc=home" -W -f 01-struttura.ldif
#  -x simple bind  | -D chi sei (admin)  | -W chiede la password  | -f file
```

Esempio di **errore di schema** (formativo): creare un `inetOrgPerson` senza `sn`
→ `ldap_add: Object class violation (65) ... requires attribute 'sn'`.

### Hashing della password utente

```bash
slappasswd -h {SSHA}      # genera {SSHA}<hash+salt>; il salt rende l'hash diverso ogni volta
```

```ldif
# fix-password.ldif
dn: uid=mzelli,ou=people,dc=lab,dc=home
changetype: modify
replace: userPassword
userPassword: {SSHA}...
```

```bash
ldapmodify -x -D "cn=admin,dc=lab,dc=home" -W -f fix-password.ldif
```

### Autenticare un utente

```bash
ldapwhoami -x -D "uid=mzelli,ou=people,dc=lab,dc=home" -W
# risposta attesa: dn:uid=mzelli,ou=people,dc=lab,dc=home
```

> Le ACL di default nascondono `userPassword` al bind anonimo: cambia *chi sei*,
> cambia *cosa vedi*.

### Leggere lo schema vivo

```bash
ldapsearch -x -LLL -o ldif-wrap=no -H ldap://localhost -s base -b cn=subschema objectClasses \
  | grep "'organizationalUnit'"      # mostra MUST/MAY della classe
```

---

## 3. TLS: teoria e pratica

### Concetti

- **Crittografia asimmetrica**: coppia chiave privata/pubblica. Si firma con la
  privata, si verifica con la pubblica.
- **Certificato**: una chiave pubblica + un'identità (CN e soprattutto **SAN**) +
  validità + **firma** di chi lo emette. È un documento d'identità.
- **CA** (Certificate Authority): la radice della fiducia. Chi si fida della CA si
  fida di ogni certificato che essa firma. In lab si crea una **CA privata**.
- **SAN** (Subject Alternative Names): i nomi/IP per cui il cert è valido. La
  verifica TLS moderna **ignora il CN** e controlla i SAN.
- Due coppie di chiavi separate (CA + server) per **isolamento del danno**.

### Comandi manuali (openssl)

```bash
# CA
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj "/O=Lab/CN=Lab Root CA"

# Server: key, CSR (con SAN), firma con la CA
openssl genrsa -out ldap.key 2048
openssl req -new -key ldap.key -out ldap.csr -subj "/O=Lab/CN=ldap.lab.home"
cat > ldap.ext <<'EOF'
subjectAltName = DNS:ldap.lab.home, DNS:ldap.local, IP:192.168.1.76
EOF
openssl x509 -req -in ldap.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 825 -out ldap.crt -extfile ldap.ext
```

La **CSR** contiene solo la chiave *pubblica* + il nome: la chiave privata del
server non lascia mai il server.

### Posizionamento e permessi (slapd gira come utente `openldap`)

```bash
sudo cp ca.crt  /etc/ssl/certs/lab-ca.crt
sudo cp ldap.crt /etc/ldap/ldap.crt
sudo cp ldap.key /etc/ldap/ldap.key
sudo chgrp openldap /etc/ldap/ldap.key      # #1 causa di TLS rotto: la chiave dev'essere leggibile da openldap
sudo chmod 0640 /etc/ldap/ldap.key
```

### Configurare TLS in cn=config

```ldif
# certinfo.ldif
dn: cn=config
changetype: modify
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ssl/certs/lab-ca.crt
-
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ldap/ldap.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ldap/ldap.key
```

```bash
sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f certinfo.ldif   # SASL EXTERNAL: root sul socket = la credenziale
```

### Abilitare LDAPS (636) e fiducia del client

```bash
# /etc/default/slapd -> aggiungere ldaps:/// a SLAPD_SERVICES, poi:
sudo systemctl restart slapd
echo "TLS_CACERT /etc/ssl/certs/lab-ca.crt" | sudo tee -a /etc/ldap/ldap.conf
echo "192.168.1.76  ldap.lab.home ldap.local" | sudo tee -a /etc/hosts
```

### Test

```bash
ldapwhoami -x -ZZ -H ldap://ldap.lab.home -D "uid=mzelli,..." -W   # StartTLS (389)
ldapwhoami -x     -H ldaps://ldap.lab.home -D "uid=mzelli,..." -W   # LDAPS (636)
openssl s_client -connect ldap.lab.home:636 -CAfile /etc/ssl/certs/lab-ca.crt </dev/null | grep -i verify
```

A runtime, il client verifica: (a) il cert è firmato da una CA fidata? (b) il nome
richiesto è tra i SAN? (c) è dentro le date? Poi apre il canale; **solo dentro** il
canale cifrato avviene il bind.

> Nota: su Ubuntu slapd è linkato a **GnuTLS** (non OpenSSL); irrilevante per i
> certificati PEM standard, rilevante solo per cipher suite personalizzate.

---

## 4. Come LDAP viene "consumato" (NSS / PAM / SSSD)

**LDAP è passivo**: viene *interrogato*. Sono le altre macchine, configurate come
client, ad andare a chiedere. La centralizzazione nasce da qui: un utente in un
punto, visto da tutti.

**Authentication ≠ Authorization:**
- **authN** = "sei chi dici?" → è il **bind** LDAP.
- **authZ** = "cosa puoi fare qui?" → la decisione la prende il consumatore usando i
  fatti di LDAP (specialmente l'appartenenza ai gruppi).

**I pezzi del login di sistema:**
- **NSS** risolve l'identità Unix (UID/GID/home/shell) — usa `posixAccount`.
- **PAM** verifica la password (bind a LDAP) e l'accesso.
- **SSSD** è la colla che chiama LDAP per entrambi, in TLS, con cache (login
  offline). È **lo stesso strumento con cui Linux si unisce ad AD**.

**Tre fasi PAM** (ordine):
`auth` (bind) → `account` (controllo d'accesso) → `session` (es. creazione home).
Due messaggi diversi rivelano le due frontiere:
- `Authentication failure` = fase auth (password sbagliata) → *non sei chi dici*.
- `Permission denied` = fase account (non autorizzato) → *sei tu, ma non puoi entrare qui*.

> Per il login Unix l'utente serve `posixAccount` (`uidNumber`, `gidNumber`,
> `homeDirectory`, `loginShell`); `inetOrgPerson` da solo basta solo ad autenticare
> applicazioni.

---

## 5. Automazione: ruolo `ldap_server`

Struttura:

```
roles/ldap_server/
├── defaults/main.yml
├── tasks/{main,install,structure,tls}.yml
├── handlers/main.yml
└── templates/
```

### defaults/main.yml (estratto)

```yaml
ldap_server_admin_password: "{{ lookup('env', 'LDAP_SERVER_ADMIN_PASSWORD') }}"
ldap_server_domain: "lab.home"
ldap_server_organization: "Lab"
ldap_server_backend: "MDB"
ldap_server_base_dn: "dc={{ ldap_server_domain.split('.') | join(',dc=') }}"

ldap_server_users:
  - uid: mzelli
    cn: "Martina Zelli"
    sn: "Zelli"
    mail: "mzelli@lab.home"
    password_env: "LDAP_SERVER_USER_MZELLI_PASSWORD"   # NOME della var env, non il valore
    uid_number: 10000
    gid_number: 10000
    login_shell: /bin/bash

ldap_server_groups:
  - cn: devops
    gid_number: 10000
    members: [mzelli]

# --- TLS ---
ldap_server_tls_enabled: true
ldap_server_fqdn: "ldap.{{ ldap_server_domain }}"
ldap_server_ca_key: /etc/ldap/lab-ca.key
ldap_server_ca_cert: /etc/ldap/lab-ca.crt
ldap_server_tls_key: /etc/ldap/ldap.key
ldap_server_tls_cert: /etc/ldap/ldap.crt
ldap_server_tls_csr: /etc/ldap/ldap.csr
```

### install.yml — installazione non interattiva (debconf preseed)

L'ordine è sacro: **prima** si preseedano le risposte, **poi** si installa.

```yaml
- name: Installa debconf-utils
  ansible.builtin.apt:
    name: debconf-utils
    state: present
    update_cache: true

- name: Preconfigura le risposte debconf di slapd
  ansible.builtin.debconf:
    name: slapd
    question: "{{ item.question }}"
    vtype: "{{ item.vtype }}"
    value: "{{ item.value }}"
  loop:
    - { question: "slapd/domain",            vtype: "string",  value: "{{ ldap_server_domain }}" }
    - { question: "shared/organization",     vtype: "string",  value: "{{ ldap_server_organization }}" }
    - { question: "slapd/backend",           vtype: "select",  value: "{{ ldap_server_backend }}" }
    - { question: "slapd/no_configuration",  vtype: "boolean", value: "false" }
    - { question: "slapd/purge_database",    vtype: "boolean", value: "false" }
    - { question: "slapd/move_old_database", vtype: "boolean", value: "true" }
    - { question: "slapd/allow_ldap_v2",     vtype: "boolean", value: "false" }
  loop_control:
    label: "{{ item.question }}"

- name: Preconfigura la password admin (decifrata da env/vault)
  # NOTA: questo task risulta sempre 'changed' perché debconf non rilegge le
  # password per confrontarle (idempotenza imperfetta, innocua). Debito gestito.
  ansible.builtin.debconf:
    name: slapd
    question: "{{ item }}"
    vtype: password
    value: "{{ ldap_server_admin_password }}"
  loop: ["slapd/password1", "slapd/password2"]
  no_log: true

- name: Installa slapd, client LDAP, e librerie Python per i moduli Ansible
  ansible.builtin.apt:
    name:
      - slapd
      - ldap-utils
      - python3-ldap          # richiesto da community.general.ldap_*
      - python3-cryptography  # richiesto da community.crypto
    state: present
  environment:
    DEBIAN_FRONTEND: noninteractive
```

### structure.yml — struttura, utenti, attributi POSIX, gruppi

Pattern ricorrente: **`ldap_entry`** gestisce l'*esistenza*, **`ldap_attrs`**
(`state: exact`) gestisce gli *attributi* in modo idempotente-sulle-modifiche.

```yaml
- name: Crea le unità organizzative
  community.general.ldap_entry:
    server_uri: "ldap://localhost/"
    bind_dn: "cn=admin,{{ ldap_server_base_dn }}"
    bind_pw: "{{ ldap_server_admin_password }}"
    dn: "ou={{ item }},{{ ldap_server_base_dn }}"
    objectClass: organizationalUnit
    attributes: { ou: "{{ item }}" }
  loop: [people, groups]

- name: Crea gli utenti (inetOrgPerson)
  community.general.ldap_entry:
    server_uri: "ldap://localhost/"
    bind_dn: "cn=admin,{{ ldap_server_base_dn }}"
    bind_pw: "{{ ldap_server_admin_password }}"
    dn: "uid={{ item.uid }},ou=people,{{ ldap_server_base_dn }}"
    objectClass: inetOrgPerson
    attributes:
      uid: "{{ item.uid }}"
      cn: "{{ item.cn }}"
      sn: "{{ item.sn }}"
      mail: "{{ item.mail }}"
      userPassword: "{{ lookup('env', item.password_env) }}"   # hash {SSHA} dal .env
  loop: "{{ ldap_server_users }}"
  loop_control: { label: "{{ item.uid }}" }
  no_log: true

- name: Aggiungi gli attributi POSIX agli utenti (login di sistema)
  community.general.ldap_attrs:
    server_uri: "ldap://localhost/"
    bind_dn: "cn=admin,{{ ldap_server_base_dn }}"
    bind_pw: "{{ ldap_server_admin_password }}"
    dn: "uid={{ item.uid }},ou=people,{{ ldap_server_base_dn }}"
    state: exact
    attributes:
      objectClass: [inetOrgPerson, posixAccount]   # exact: elencare ENTRAMBE, altrimenti rimuove inetOrgPerson
      uidNumber: "{{ item.uid_number }}"
      gidNumber: "{{ item.gid_number }}"
      homeDirectory: "/home/{{ item.uid }}"
      loginShell: "{{ item.login_shell }}"
  loop: "{{ ldap_server_users }}"
  loop_control: { label: "{{ item.uid }}" }

- name: Crea i gruppi POSIX (esistenza)
  community.general.ldap_entry:
    server_uri: "ldap://localhost/"
    bind_dn: "cn=admin,{{ ldap_server_base_dn }}"
    bind_pw: "{{ ldap_server_admin_password }}"
    dn: "cn={{ item.cn }},ou=groups,{{ ldap_server_base_dn }}"
    objectClass: posixGroup
    attributes:
      cn: "{{ item.cn }}"
      gidNumber: "{{ item.gid_number }}"
  loop: "{{ ldap_server_groups }}"
  loop_control: { label: "{{ item.cn }}" }

- name: Imposta i membri dei gruppi POSIX
  community.general.ldap_attrs:
    server_uri: "ldap://localhost/"
    bind_dn: "cn=admin,{{ ldap_server_base_dn }}"
    bind_pw: "{{ ldap_server_admin_password }}"
    dn: "cn={{ item.cn }},ou=groups,{{ ldap_server_base_dn }}"
    state: exact
    attributes: { memberUid: "{{ item.members }}" }
  loop: "{{ ldap_server_groups }}"
  loop_control: { label: "{{ item.cn }}" }
```

### tls.yml — PKI + cn=config + LDAPS

I moduli `community.crypto` sono il wrapper idempotente di openssl.

```yaml# Percorso LDAP → fondamenta di Active Directory

Documento di riepilogo del percorso di studio LDAP: dalla teoria, alla pratica
manuale, fino all'implementazione completa come codice (Ansible) di un sistema di
identità centralizzata.

**Vincoli rispettati:** tutto in rete locale, solo software open-source.
**Stack:** OpenLDAP (slapd 2.6.x) su Ubuntu 24.04, VM via Terraform/OpenTofu
(libvirt/KVM), automazione con Ansible, client con SSSD.

---

## Indice

1. Teoria LDAP
2. Fase manuale (runbook dei comandi)
3. TLS: teoria e pratica
4. Come LDAP viene "consumato" (NSS / PAM / SSSD)
5. Automazione: ruolo `ldap_server`
6. Automazione: ruolo `ldap_client`
7. Lezioni DevOps trasversali
8. Gotcha incontrati e soluzioni
9. Comandi di verifica
10. Cosa resta da fare

---

## 1. Teoria LDAP

**Cos'è.** LDAP (*Lightweight Directory Access Protocol*) è un **protocollo**
client-server (non un prodotto) per accedere a un *directory service*. Versione
LDAPv3 (RFC 4510–4519). Porte: **389** (in chiaro / StartTLS), **636** (LDAPS).
OpenLDAP (`slapd`) è *un'implementazione*; Active Directory è un'altra.

**Perché non un DB relazionale.** Una directory è ottimizzata per
**letture frequenti, scritture rare, dati gerarchici** interrogati per attributo.
Niente JOIN/transazioni complesse; in cambio, letture velocissime e struttura ad
albero nativa. È il motivo per cui l'autenticazione centralizzata usa LDAP.

**Il modello: il DIT** (*Directory Information Tree*), albero gerarchico di entry.

```
dc=lab,dc=home            <- radice (base DN / suffix)
├── ou=people
│   └── uid=mzelli        <- entry utente
└── ou=groups
    └── cn=devops
```

### Vocabolario

- **Entry**: un nodo dell'albero.
- **DN** (*Distinguished Name*): percorso assoluto univoco, es.
  `uid=mzelli,ou=people,dc=lab,dc=home`. Si legge **da sinistra (foglia) a destra
  (radice)** — opposto di un path Unix.
- **RDN**: il pezzo più a sinistra del DN (`uid=mzelli`).
- **Attributo**: coppia chiave→valore; può essere multi-valore.
- **objectClass**: dichiara il *tipo* di entry e quindi quali attributi sono
  obbligatori (**MUST**) e permessi (**MAY**). È il "contratto" della entry.
- **Schema**: il regolamento del server (quali classi/attributi esistono). Il
  server **rifiuta** entry che lo violano — come un compilatore con tipi forti.
- **Prefissi naming**: `dc`=domain component, `ou`=organizational unit (contenitore),
  `cn`=common name, `uid`=user id.

### Ereditarietà degli objectClass

Le classi formano una catena via l'attributo **`SUP`** (superior), e MUST/MAY si
ereditano lungo di essa:

```
inetOrgPerson → organizationalPerson → person → top
                                       MUST: sn, cn   <- l'obbligo viene da qui
```

Per questo creando un `inetOrgPerson` serve `sn`: lo eredita da `person`.

### Operazioni (i "verbi")

- **bind**: autenticarsi. Modalità: *anonima*, *simple bind* (DN+password),
  *SASL* (es. EXTERNAL via socket).
- **search**: base DN + **scope** + filtro + attributi.
  - scope: `base` (solo la entry), `one` (figli diretti), `sub` (tutto il sottoalbero, default).
- **add / modify / delete / modrdn**: creare / modificare / cancellare / rinominare.

### Filtri (RFC 4515)

- `(uid=mzelli)` — uguaglianza
- `(&(objectClass=inetOrgPerson)(mail=*))` — AND
- `(|(uid=a)(uid=b))` — OR
- `(!(uid=admin))` — NOT

### LDIF

Formato testuale per entry e modifiche. Entry separate da **riga vuota**.

```ldif
dn: uid=mzelli,ou=people,dc=lab,dc=home
objectClass: inetOrgPerson
uid: mzelli
cn: Martina Zelli
sn: Zelli
```

Per le **modifiche**, sintassi con `changetype`:

```ldif
dn: uid=mzelli,ou=people,dc=lab,dc=home
changetype: modify
replace: userPassword
userPassword: {SSHA}...
```

(Il trattino `-` su riga singola separa più operazioni sulla stessa entry.)

### I due alberi amministrativi

| | albero dati | albero config |
|---|---|---|
| DN radice | `dc=lab,dc=home` | `cn=config` |
| autenticazione | simple bind (`-x -D ... -W`) | SASL EXTERNAL (`-Y EXTERNAL -H ldapi:///`) |
| identità | `cn=admin` + password | utente **root del SO** (via `sudo`) |

---

## 2. Fase manuale (runbook dei comandi)

> Nota: tutti i comandi vanno eseguiti **sulla VM Ubuntu**, non sul PC Arch.

### Installazione e base DN

```bash
sudo apt update
sudo apt install -y slapd ldap-utils      # slapd = server; ldap-utils = client CLI
sudo dpkg-reconfigure slapd               # imposta dominio -> base DN dc=lab,dc=home, backend MDB
```

La password chiesta è quella dell'**admin LDAP** (`cn=admin,dc=lab,dc=home`),
distinta da SSH / utente di sistema / sudo. Serve a ogni *scrittura*.

### Verifica e ispezione

```bash
systemctl status slapd
ss -tlnp | grep 389
ldapsearch -x -LLL -H ldap://localhost -b "dc=lab,dc=home"      # bind anonimo
sudo slapcat                                                    # legge il DB su disco (mostra i metadati operazionali)
```

`ldapsearch` parla via rete e rispetta le ACL; `slapcat` legge il DB grezzo.

### Struttura e utenti

```ldif
# 01-struttura.ldif
dn: ou=people,dc=lab,dc=home
objectClass: organizationalUnit
ou: people

dn: ou=groups,dc=lab,dc=home
objectClass: organizationalUnit
ou: groups
```

```bash
ldapadd -x -D "cn=admin,dc=lab,dc=home" -W -f 01-struttura.ldif
#  -x simple bind  | -D chi sei (admin)  | -W chiede la password  | -f file
```

Esempio di **errore di schema** (formativo): creare un `inetOrgPerson` senza `sn`
→ `ldap_add: Object class violation (65) ... requires attribute 'sn'`.

### Hashing della password utente

```bash
slappasswd -h {SSHA}      # genera {SSHA}<hash+salt>; il salt rende l'hash diverso ogni volta
```

```ldif
# fix-password.ldif
dn: uid=mzelli,ou=people,dc=lab,dc=home
changetype: modify
replace: userPassword
userPassword: {SSHA}...
```

```bash
ldapmodify -x -D "cn=admin,dc=lab,dc=home" -W -f fix-password.ldif
```

### Autenticare un utente

```bash
ldapwhoami -x -D "uid=mzelli,ou=people,dc=lab,dc=home" -W
# risposta attesa: dn:uid=mzelli,ou=people,dc=lab,dc=home
```

> Le ACL di default nascondono `userPassword` al bind anonimo: cambia *chi sei*,
> cambia *cosa vedi*.

### Leggere lo schema vivo

```bash
ldapsearch -x -LLL -o ldif-wrap=no -H ldap://localhost -s base -b cn=subschema objectClasses \
  | grep "'organizationalUnit'"      # mostra MUST/MAY della classe
```

---

## 3. TLS: teoria e pratica

### Concetti

- **Crittografia asimmetrica**: coppia chiave privata/pubblica. Si firma con la
  privata, si verifica con la pubblica.
- **Certificato**: una chiave pubblica + un'identità (CN e soprattutto **SAN**) +
  validità + **firma** di chi lo emette. È un documento d'identità.
- **CA** (Certificate Authority): la radice della fiducia. Chi si fida della CA si
  fida di ogni certificato che essa firma. In lab si crea una **CA privata**.
- **SAN** (Subject Alternative Names): i nomi/IP per cui il cert è valido. La
  verifica TLS moderna **ignora il CN** e controlla i SAN.
- Due coppie di chiavi separate (CA + server) per **isolamento del danno**.

### Comandi manuali (openssl)

```bash
# CA
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj "/O=Lab/CN=Lab Root CA"

# Server: key, CSR (con SAN), firma con la CA
openssl genrsa -out ldap.key 2048
openssl req -new -key ldap.key -out ldap.csr -subj "/O=Lab/CN=ldap.lab.home"
cat > ldap.ext <<'EOF'
subjectAltName = DNS:ldap.lab.home, DNS:ldap.local, IP:192.168.1.76
EOF
openssl x509 -req -in ldap.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 825 -out ldap.crt -extfile ldap.ext
```

La **CSR** contiene solo la chiave *pubblica* + il nome: la chiave privata del
server non lascia mai il server.

### Posizionamento e permessi (slapd gira come utente `openldap`)

```bash
sudo cp ca.crt  /etc/ssl/certs/lab-ca.crt
sudo cp ldap.crt /etc/ldap/ldap.crt
sudo cp ldap.key /etc/ldap/ldap.key
sudo chgrp openldap /etc/ldap/ldap.key      # #1 causa di TLS rotto: la chiave dev'essere leggibile da openldap
sudo chmod 0640 /etc/ldap/ldap.key
```

### Configurare TLS in cn=config

```ldif
# certinfo.ldif
dn: cn=config
changetype: modify
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ssl/certs/lab-ca.crt
-
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ldap/ldap.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ldap/ldap.key
```

```bash
sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f certinfo.ldif   # SASL EXTERNAL: root sul socket = la credenziale
```

### Abilitare LDAPS (636) e fiducia del client

```bash
# /etc/default/slapd -> aggiungere ldaps:/// a SLAPD_SERVICES, poi:
sudo systemctl restart slapd
echo "TLS_CACERT /etc/ssl/certs/lab-ca.crt" | sudo tee -a /etc/ldap/ldap.conf
echo "192.168.1.76  ldap.lab.home ldap.local" | sudo tee -a /etc/hosts
```

### Test

```bash
ldapwhoami -x -ZZ -H ldap://ldap.lab.home -D "uid=mzelli,..." -W   # StartTLS (389)
ldapwhoami -x     -H ldaps://ldap.lab.home -D "uid=mzelli,..." -W   # LDAPS (636)
openssl s_client -connect ldap.lab.home:636 -CAfile /etc/ssl/certs/lab-ca.crt </dev/null | grep -i verify
```

A runtime, il client verifica: (a) il cert è firmato da una CA fidata? (b) il nome
richiesto è tra i SAN? (c) è dentro le date? Poi apre il canale; **solo dentro** il
canale cifrato avviene il bind.

> Nota: su Ubuntu slapd è linkato a **GnuTLS** (non OpenSSL); irrilevante per i
> certificati PEM standard, rilevante solo per cipher suite personalizzate.

---

## 4. Come LDAP viene "consumato" (NSS / PAM / SSSD)

**LDAP è passivo**: viene *interrogato*. Sono le altre macchine, configurate come
client, ad andare a chiedere. La centralizzazione nasce da qui: un utente in un
punto, visto da tutti.

**Authentication ≠ Authorization:**
- **authN** = "sei chi dici?" → è il **bind** LDAP.
- **authZ** = "cosa puoi fare qui?" → la decisione la prende il consumatore usando i
  fatti di LDAP (specialmente l'appartenenza ai gruppi).

**I pezzi del login di sistema:**
- **NSS** risolve l'identità Unix (UID/GID/home/shell) — usa `posixAccount`.
- **PAM** verifica la password (bind a LDAP) e l'accesso.
- **SSSD** è la colla che chiama LDAP per entrambi, in TLS, con cache (login
  offline). È **lo stesso strumento con cui Linux si unisce ad AD**.

**Tre fasi PAM** (ordine):
`auth` (bind) → `account` (controllo d'accesso) → `session` (es. creazione home).
Due messaggi diversi rivelano le due frontiere:
- `Authentication failure` = fase auth (password sbagliata) → *non sei chi dici*.
- `Permission denied` = fase account (non autorizzato) → *sei tu, ma non puoi entrare qui*.

> Per il login Unix l'utente serve `posixAccount` (`uidNumber`, `gidNumber`,
> `homeDirectory`, `loginShell`); `inetOrgPerson` da solo basta solo ad autenticare
> applicazioni.

---

## 5. Automazione: ruolo `ldap_server`

Struttura:

```
roles/ldap_server/
├── defaults/main.yml
├── tasks/{main,install,structure,tls}.yml
├── handlers/main.yml
└── templates/
```

### defaults/main.yml (estratto)

```yaml
ldap_server_admin_password: "{{ lookup('env', 'LDAP_SERVER_ADMIN_PASSWORD') }}"
ldap_server_domain: "lab.home"
ldap_server_organization: "Lab"
ldap_server_backend: "MDB"
ldap_server_base_dn: "dc={{ ldap_server_domain.split('.') | join(',dc=') }}"

ldap_server_users:
  - uid: mzelli
    cn: "Martina Zelli"
    sn: "Zelli"
    mail: "mzelli@lab.home"
    password_env: "LDAP_SERVER_USER_MZELLI_PASSWORD"   # NOME della var env, non il valore
    uid_number: 10000
    gid_number: 10000
    login_shell: /bin/bash

ldap_server_groups:
  - cn: devops
    gid_number: 10000
    members: [mzelli]

# --- TLS ---
ldap_server_tls_enabled: true
ldap_server_fqdn: "ldap.{{ ldap_server_domain }}"
ldap_server_ca_key: /etc/ldap/lab-ca.key
ldap_server_ca_cert: /etc/ldap/lab-ca.crt
ldap_server_tls_key: /etc/ldap/ldap.key
ldap_server_tls_cert: /etc/ldap/ldap.crt
ldap_server_tls_csr: /etc/ldap/ldap.csr
```

### install.yml — installazione non interattiva (debconf preseed)

L'ordine è sacro: **prima** si preseedano le risposte, **poi** si installa.

```yaml
- name: Installa debconf-utils
  ansible.builtin.apt:
    name: debconf-utils
    state: present
    update_cache: true

- name: Preconfigura le risposte debconf di slapd
  ansible.builtin.debconf:
    name: slapd
    question: "{{ item.question }}"
    vtype: "{{ item.vtype }}"
    value: "{{ item.value }}"
  loop:
    - { question: "slapd/domain",            vtype: "string",  value: "{{ ldap_server_domain }}" }
    - { question: "shared/organization",     vtype: "string",  value: "{{ ldap_server_organization }}" }
    - { question: "slapd/backend",           vtype: "select",  value: "{{ ldap_server_backend }}" }
    - { question: "slapd/no_configuration",  vtype: "boolean", value: "false" }
    - { question: "slapd/purge_database",    vtype: "boolean", value: "false" }
    - { question: "slapd/move_old_database", vtype: "boolean", value: "true" }
    - { question: "slapd/allow_ldap_v2",     vtype: "boolean", value: "false" }
  loop_control:
    label: "{{ item.question }}"

- name: Preconfigura la password admin (decifrata da env/vault)
  # NOTA: questo task risulta sempre 'changed' perché debconf non rilegge le
  # password per confrontarle (idempotenza imperfetta, innocua). Debito gestito.
  ansible.builtin.debconf:
    name: slapd
    question: "{{ item }}"
    vtype: password
    value: "{{ ldap_server_admin_password }}"
  loop: ["slapd/password1", "slapd/password2"]
  no_log: true

- name: Installa slapd, client LDAP, e librerie Python per i moduli Ansible
  ansible.builtin.apt:
    name:
      - slapd
      - ldap-utils
      - python3-ldap          # richiesto da community.general.ldap_*
      - python3-cryptography  # richiesto da community.crypto
    state: present
  environment:
    DEBIAN_FRONTEND: noninteractive
```

### structure.yml — struttura, utenti, attributi POSIX, gruppi

Pattern ricorrente: **`ldap_entry`** gestisce l'*esistenza*, **`ldap_attrs`**
(`state: exact`) gestisce gli *attributi* in modo idempotente-sulle-modifiche.

```yaml
- name: Crea le unità organizzative
  community.general.ldap_entry:
    server_uri: "ldap://localhost/"
    bind_dn: "cn=admin,{{ ldap_server_base_dn }}"
    bind_pw: "{{ ldap_server_admin_password }}"
    dn: "ou={{ item }},{{ ldap_server_base_dn }}"
    objectClass: organizationalUnit
    attributes: { ou: "{{ item }}" }
  loop: [people, groups]

- name: Crea gli utenti (inetOrgPerson)
  community.general.ldap_entry:
    server_uri: "ldap://localhost/"
    bind_dn: "cn=admin,{{ ldap_server_base_dn }}"
    bind_pw: "{{ ldap_server_admin_password }}"
    dn: "uid={{ item.uid }},ou=people,{{ ldap_server_base_dn }}"
    objectClass: inetOrgPerson
    attributes:
      uid: "{{ item.uid }}"
      cn: "{{ item.cn }}"
      sn: "{{ item.sn }}"
      mail: "{{ item.mail }}"
      userPassword: "{{ lookup('env', item.password_env) }}"   # hash {SSHA} dal .env
  loop: "{{ ldap_server_users }}"
  loop_control: { label: "{{ item.uid }}" }
  no_log: true

- name: Aggiungi gli attributi POSIX agli utenti (login di sistema)
  community.general.ldap_attrs:
    server_uri: "ldap://localhost/"
    bind_dn: "cn=admin,{{ ldap_server_base_dn }}"
    bind_pw: "{{ ldap_server_admin_password }}"
    dn: "uid={{ item.uid }},ou=people,{{ ldap_server_base_dn }}"
    state: exact
    attributes:
      objectClass: [inetOrgPerson, posixAccount]   # exact: elencare ENTRAMBE, altrimenti rimuove inetOrgPerson
      uidNumber: "{{ item.uid_number }}"
      gidNumber: "{{ item.gid_number }}"
      homeDirectory: "/home/{{ item.uid }}"
      loginShell: "{{ item.login_shell }}"
  loop: "{{ ldap_server_users }}"
  loop_control: { label: "{{ item.uid }}" }

- name: Crea i gruppi POSIX (esistenza)
  community.general.ldap_entry:
    server_uri: "ldap://localhost/"
    bind_dn: "cn=admin,{{ ldap_server_base_dn }}"
    bind_pw: "{{ ldap_server_admin_password }}"
    dn: "cn={{ item.cn }},ou=groups,{{ ldap_server_base_dn }}"
    objectClass: posixGroup
    attributes:
      cn: "{{ item.cn }}"
      gidNumber: "{{ item.gid_number }}"
  loop: "{{ ldap_server_groups }}"
  loop_control: { label: "{{ item.cn }}" }

- name: Imposta i membri dei gruppi POSIX
  community.general.ldap_attrs:
    server_uri: "ldap://localhost/"
    bind_dn: "cn=admin,{{ ldap_server_base_dn }}"
    bind_pw: "{{ ldap_server_admin_password }}"
    dn: "cn={{ item.cn }},ou=groups,{{ ldap_server_base_dn }}"
    state: exact
    attributes: { memberUid: "{{ item.members }}" }
  loop: "{{ ldap_server_groups }}"
  loop_control: { label: "{{ item.cn }}" }
```

### tls.yml — PKI + cn=config + LDAPS

I moduli `community.crypto` sono il wrapper idempotente di openssl.

```yaml
# CA
- community.crypto.openssl_privatekey: { path: "{{ ldap_server_ca_key }}", mode: "0600" }
- community.crypto.openssl_csr:
    path: /etc/ldap/lab-ca.csr
    privatekey_path: "{{ ldap_server_ca_key }}"
    common_name: "Lab Root CA"
    basic_constraints: ["CA:TRUE"]
    basic_constraints_critical: true
    key_usage: [keyCertSign, cRLSign]
    key_usage_critical: true
    use_common_name_for_san: false
- community.crypto.x509_certificate:
    path: "{{ ldap_server_ca_cert }}"
    csr_path: /etc/ldap/lab-ca.csr
    privatekey_path: "{{ ldap_server_ca_key }}"
    provider: selfsigned
    mode: "0644"

# Server
- community.crypto.openssl_privatekey:
    path: "{{ ldap_server_tls_key }}"
    group: openldap          # leggibile da slapd
    mode: "0640"
- community.crypto.openssl_csr:
    path: "{{ ldap_server_tls_csr }}"
    privatekey_path: "{{ ldap_server_tls_key }}"
    common_name: "{{ ldap_server_fqdn }}"
    subject_alt_name:
      - "DNS:{{ ldap_server_fqdn }}"
      - "DNS:ldap.local"
      - "IP:{{ ansible_host }}"
- community.crypto.x509_certificate:
    path: "{{ ldap_server_tls_cert }}"
    csr_path: "{{ ldap_server_tls_csr }}"
    provider: ownca
    ownca_path: "{{ ldap_server_ca_cert }}"
    ownca_privatekey_path: "{{ ldap_server_ca_key }}"
    mode: "0644"

# cn=config (SASL EXTERNAL via socket: nessun bind_dn, become root)
- community.general.ldap_attrs:
    dn: cn=config
    state: exact
    attributes:
      olcTLSCACertificateFile: "{{ ldap_server_ca_cert }}"
      olcTLSCertificateFile: "{{ ldap_server_tls_cert }}"
      olcTLSCertificateKeyFile: "{{ ldap_server_tls_key }}"
  notify: Riavvia slapd

# LDAPS + fiducia/risoluzione locali
- ansible.builtin.lineinfile:
    path: /etc/default/slapd
    regexp: '^SLAPD_SERVICES='
    line: 'SLAPD_SERVICES="ldap:/// ldapi:/// ldaps:///"'
  notify: Riavvia slapd
- ansible.builtin.lineinfile:
    path: /etc/ldap/ldap.conf
    regexp: '^TLS_CACERT'
    line: "TLS_CACERT {{ ldap_server_ca_cert }}"
- ansible.builtin.lineinfile:
    path: /etc/hosts
    regexp: '{{ ldap_server_fqdn }}'
    line: "{{ ansible_host }} {{ ldap_server_fqdn }} ldap.local"
```

### handlers/main.yml

```yaml
- name: Riavvia slapd
  ansible.builtin.service: { name: slapd, state: restarted }
```

---

## 6. Automazione: ruolo `ldap_client` (SSSD)

### defaults/main.yml

```yaml
ldap_client_domain: "lab.home"
ldap_client_base_dn: "dc={{ ldap_client_domain.split('.') | join(',dc=') }}"
ldap_client_server_fqdn: "ldap.{{ ldap_client_domain }}"
ldap_client_server_host: "{{ groups['ldap_servers'][0] }}"
ldap_client_ca_src: /etc/ldap/lab-ca.crt          # sul SERVER
ldap_client_ca_dest: /etc/ssl/certs/lab-ca.crt    # sul CLIENT
ldap_client_allowed_groups: "devops"
ldap_client_ssh_password_auth: false
```

### tasks/main.yml (estratto chiave)

```yaml
- name: Installa SSSD e moduli LDAP/PAM/NSS
  ansible.builtin.apt:
    name: [sssd, sssd-ldap, sssd-tools, libpam-sss, libnss-sss, ldap-utils]
    state: present
    update_cache: true

# --- Distribuzione CA tra host: slurp (sul server) -> copy (sul client) ---
- name: Leggi il certificato CA DAL SERVER
  ansible.builtin.slurp:
    src: "{{ ldap_client_ca_src }}"
  delegate_to: "{{ ldap_client_server_host }}"     # gira sul SERVER
  register: ldap_ca_slurp

- name: Installa il certificato CA SUL CLIENT
  ansible.builtin.copy:
    content: "{{ ldap_ca_slurp.content | b64decode }}"   # slurp restituisce Base64
    dest: "{{ ldap_client_ca_dest }}"
    owner: root
    group: root
    mode: "0644"

- name: Risolvi il FQDN del server
  ansible.builtin.lineinfile:
    path: /etc/hosts
    regexp: "{{ ldap_client_server_fqdn }}"
    line: "{{ hostvars[ldap_client_server_host].ansible_host }} {{ ldap_client_server_fqdn }}"

- name: Scrivi /etc/sssd/sssd.conf
  ansible.builtin.template:
    src: sssd.conf.j2
    dest: /etc/sssd/sssd.conf
    owner: root
    group: root
    mode: "0600"          # OBBLIGATORIO: sssd non parte se non è 0600 root:root
  notify: Riavvia sssd

# --- PAM: command è l'ultima spiaggia (no modulo dedicato) reso onesto ---
- name: Leggi la configurazione PAM corrente
  ansible.builtin.slurp: { src: /etc/pam.d/common-session }
  register: ldap_client_pam_common_session

- name: Abilita SSSD e creazione home in PAM
  ansible.builtin.command: pam-auth-update --enable sssd --enable mkhomedir
  when: "'pam_mkhomedir.so' not in (ldap_client_pam_common_session.content | b64decode)"
  changed_when: true
  notify: Riavvia sssd
```

### templates/sssd.conf.j2

```jinja
[sssd]
config_file_version = 2
services = nss, pam
domains = {{ ldap_client_domain }}

[domain/{{ ldap_client_domain }}]
id_provider = ldap
auth_provider = ldap
ldap_uri = ldaps://{{ ldap_client_server_fqdn }}
ldap_search_base = {{ ldap_client_base_dn }}
ldap_tls_cacert = {{ ldap_client_ca_dest }}
ldap_tls_reqcert = hard
cache_credentials = true
access_provider = simple
simple_allow_groups = {{ ldap_client_allowed_groups }}
```

### handlers/main.yml

```yaml
- name: Riavvia sssd
  ansible.builtin.service: { name: sssd, state: restarted, enabled: true }
```

### Inventory e playbook

```yaml
# inventory.yml
ldap_servers:
  hosts: { ldap: { ansible_host: "{{ ip.ldap_ip }}" } }
ldap_clients:
  hosts: { lb: }        # 'lb' è lo stesso host già in lb_servers (un host, più gruppi)
```

```yaml
# ldap.yml
- name: Configura il server LDAP
  hosts: ldap_servers
  become: true
  roles: [ldap_server]

- name: Configura i client LDAP
  hosts: ldap_clients
  become: true
  roles: [ldap_client]
```

---

## 7. Lezioni DevOps trasversali

- **Idempotenza**: la prova non è creare, è **ri**lanciare e ottenere `changed=0`.
  `ldap_entry` = esistenza; `ldap_attrs state: exact` = attributi (converge sulle modifiche).
- **Segreti fuori dal repo**: password (anzi, **hash**) nel `.env` gitignorato; il
  ruolo conosce solo la variabile, non la sorgente (disaccoppiamento → swap a vault
  = una riga in `group_vars`). `no_log: true` sui task con segreti.
- **debconf preseed**: pre-rispondere alle domande PRIMA dell'install per pacchetti
  interattivi. Agisce solo su install pulita.
- **Handler + notify**: riavvii solo quando qualcosa cambia davvero.
- **`command` con le tre cinture**: (1) esiste un modulo dedicato? (2) `when` per non
  girare a vuoto; (3) `changed_when` per dichiarare l'effetto onestamente.
- **Orchestrazione multi-host**: `slurp` + `delegate_to` + `copy content=` per far
  viaggiare un dato tra host (es. la CA dal server al client).
- **Distruggi-e-ricostruisci**: l'unico modo di provare un ruolo *da zero*. Il
  **disco** è l'OS: per una VM pulita si replica il *volume*, non solo il dominio
  (`tofu apply -replace='libvirt_volume.vm_disk["x"]' -replace='libvirt_domain.vm["x"]'`).
- **Leggere il `plan`/`RECAP`**: `0 to destroy` è il semaforo; `changed` vs `ok`
  racconta la verità (o il falso positivo da indagare).

---

## 8. Gotcha incontrati e soluzioni

- **`apt` non esiste su Arch**: i comandi server vanno sulla VM Ubuntu, non sul PC.
- **Password debconf chiesta in install**: è la password admin LDAP, non SSH.
- **`-replace` del solo dominio non pulisce l'OS**: serve replicare anche il volume disco.
- **Falso positivo "tutto ok"**: se l'install di slapd è `ok` (non `changed`), la VM
  non era pulita e il preseed non è stato consumato.
- **`REMOTE HOST IDENTIFICATION HAS CHANGED`**: nuove chiavi host dopo rebuild →
  `ssh-keygen -R <ip>` (o il play che pulisce `known_hosts`).
- **`python-ldap` mancante**: i moduli `ldap_*` girano *sul target* → `python3-ldap`
  va installato sulla VM (e `python3-cryptography` per crypto).
- **`Object class violation`**: attributo MUST mancante (es. `sn` ereditato da `person`).
- **`ldap_attrs state: exact` su objectClass**: elencare TUTTE le classi, altrimenti
  rimuove quelle non citate.
- **`slappasswd` non c'è su Arch**: generarlo sulla VM via SSH, oppure con openssl.
- **`cannot find name for group ID`**: manca il `posixGroup` con quel `gidNumber`.
- **`ssh_pwauth: false` nel cloud-init**: blocca il login SSH con password → testare
  con `su - utente`.
- **`sssd.conf` non 0600**: SSSD non parte.
- **`ldap_entry` ignora gli attributi**: se la entry esiste, un cambio password nel
  `.env` non si propaga → `ldapdelete` della entry + rilancio (o passare a `ldap_attrs`).
- **Cache SSSD**: dopo modifiche, `sudo sss_cache -E`.

---

## 9. Comandi di verifica

```bash
# Inventory come lo interpreta Ansible
ansible-inventory -i inventory.yml --graph
ansible -i inventory.yml lb -m ping        # raggiungibilità (separa infra da config)

# Sul server
ss -tlnp | grep -E "389|636"
ldapsearch -x -LLL -b "dc=lab,dc=home"
ldapwhoami -x -ZZ   -H ldap://ldap.lab.home  -D "uid=mzelli,ou=people,dc=lab,dc=home" -W
ldapwhoami -x       -H ldaps://ldap.lab.home -D "uid=mzelli,ou=people,dc=lab,dc=home" -W

# Sul client (menu-lb)
getent passwd mzelli        # NSS via SSSD
id mzelli                   # uid/gid/gruppi
getent group devops
su - mzelli                 # auth + authZ + creazione home  (membro di devops -> entra)
su - esterno                # Permission denied  (non in devops: authZ nega in fase account)
sudo sss_cache -E           # svuota la cache SSSD
```

Distinzione dei messaggi di errore:
- `Authentication failure` → fase **auth** (password errata).
- `Permission denied` → fase **account** (autenticato ma non autorizzato).

---

## 10. Cosa resta da fare

- **Irrobustimento del ruolo**: gestire `userPassword` con `ldap_attrs` (`state: exact`)
  invece che con `ldap_entry`, così un cambio di hash nel `.env` si propaga da solo.
- **`ansible-vault`**: sostituire il `.env` per i segreti (cambia solo la riga in
  `group_vars/ldap_servers.yml`, da `lookup('env')` al blocco `!vault`).
- **Verso Active Directory**: AD = questo modello + **Kerberos** (autenticazione a
  ticket invece del bind), **DNS** (service discovery), e l'**unificazione** di
  `posixGroup`/`groupOfNames` in un unico oggetto-gruppo. SSSD è già lo stesso
  strumento usato per unire Linux ad AD.

---

*Tutto realizzato in rete locale, solo software open-source, su un branch dedicato
(`feature/ldap-base`). Dalla teoria a un mini sistema di identità centralizzata
funzionante e riproducibile come codice.*
# CA
- community.crypto.openssl_privatekey: { path: "{{ ldap_server_ca_key }}", mode: "0600" }
- community.crypto.openssl_csr:
    path: /etc/ldap/lab-ca.csr
    privatekey_path: "{{ ldap_server_ca_key }}"
    common_name: "Lab Root CA"
    basic_constraints: ["CA:TRUE"]
    basic_constraints_critical: true
    key_usage: [keyCertSign, cRLSign]
    key_usage_critical: true
    use_common_name_for_san: false
- community.crypto.x509_certificate:
    path: "{{ ldap_server_ca_cert }}"
    csr_path: /etc/ldap/lab-ca.csr
    privatekey_path: "{{ ldap_server_ca_key }}"
    provider: selfsigned
    mode: "0644"

# Server
- community.crypto.openssl_privatekey:
    path: "{{ ldap_server_tls_key }}"
    group: openldap          # leggibile da slapd
    mode: "0640"
- community.crypto.openssl_csr:
    path: "{{ ldap_server_tls_csr }}"
    privatekey_path: "{{ ldap_server_tls_key }}"
    common_name: "{{ ldap_server_fqdn }}"
    subject_alt_name:
      - "DNS:{{ ldap_server_fqdn }}"
      - "DNS:ldap.local"
      - "IP:{{ ansible_host }}"
- community.crypto.x509_certificate:
    path: "{{ ldap_server_tls_cert }}"
    csr_path: "{{ ldap_server_tls_csr }}"
    provider: ownca
    ownca_path: "{{ ldap_server_ca_cert }}"
    ownca_privatekey_path: "{{ ldap_server_ca_key }}"
    mode: "0644"

# cn=config (SASL EXTERNAL via socket: nessun bind_dn, become root)
- community.general.ldap_attrs:
    dn: cn=config
    state: exact
    attributes:
      olcTLSCACertificateFile: "{{ ldap_server_ca_cert }}"
      olcTLSCertificateFile: "{{ ldap_server_tls_cert }}"
      olcTLSCertificateKeyFile: "{{ ldap_server_tls_key }}"
  notify: Riavvia slapd

# LDAPS + fiducia/risoluzione locali
- ansible.builtin.lineinfile:
    path: /etc/default/slapd
    regexp: '^SLAPD_SERVICES='
    line: 'SLAPD_SERVICES="ldap:/// ldapi:/// ldaps:///"'
  notify: Riavvia slapd
- ansible.builtin.lineinfile:
    path: /etc/ldap/ldap.conf
    regexp: '^TLS_CACERT'
    line: "TLS_CACERT {{ ldap_server_ca_cert }}"
- ansible.builtin.lineinfile:
    path: /etc/hosts
    regexp: '{{ ldap_server_fqdn }}'
    line: "{{ ansible_host }} {{ ldap_server_fqdn }} ldap.local"
```

### handlers/main.yml

```yaml
- name: Riavvia slapd
  ansible.builtin.service: { name: slapd, state: restarted }
```

---

## 6. Automazione: ruolo `ldap_client` (SSSD)

### defaults/main.yml

```yaml
ldap_client_domain: "lab.home"
ldap_client_base_dn: "dc={{ ldap_client_domain.split('.') | join(',dc=') }}"
ldap_client_server_fqdn: "ldap.{{ ldap_client_domain }}"
ldap_client_server_host: "{{ groups['ldap_servers'][0] }}"
ldap_client_ca_src: /etc/ldap/lab-ca.crt          # sul SERVER
ldap_client_ca_dest: /etc/ssl/certs/lab-ca.crt    # sul CLIENT
ldap_client_allowed_groups: "devops"
ldap_client_ssh_password_auth: false
```

### tasks/main.yml (estratto chiave)

```yaml
- name: Installa SSSD e moduli LDAP/PAM/NSS
  ansible.builtin.apt:
    name: [sssd, sssd-ldap, sssd-tools, libpam-sss, libnss-sss, ldap-utils]
    state: present
    update_cache: true

# --- Distribuzione CA tra host: slurp (sul server) -> copy (sul client) ---
- name: Leggi il certificato CA DAL SERVER
  ansible.builtin.slurp:
    src: "{{ ldap_client_ca_src }}"
  delegate_to: "{{ ldap_client_server_host }}"     # gira sul SERVER
  register: ldap_ca_slurp

- name: Installa il certificato CA SUL CLIENT
  ansible.builtin.copy:
    content: "{{ ldap_ca_slurp.content | b64decode }}"   # slurp restituisce Base64
    dest: "{{ ldap_client_ca_dest }}"
    owner: root
    group: root
    mode: "0644"

- name: Risolvi il FQDN del server
  ansible.builtin.lineinfile:
    path: /etc/hosts
    regexp: "{{ ldap_client_server_fqdn }}"
    line: "{{ hostvars[ldap_client_server_host].ansible_host }} {{ ldap_client_server_fqdn }}"

- name: Scrivi /etc/sssd/sssd.conf
  ansible.builtin.template:
    src: sssd.conf.j2
    dest: /etc/sssd/sssd.conf
    owner: root
    group: root
    mode: "0600"          # OBBLIGATORIO: sssd non parte se non è 0600 root:root
  notify: Riavvia sssd

# --- PAM: command è l'ultima spiaggia (no modulo dedicato) reso onesto ---
- name: Leggi la configurazione PAM corrente
  ansible.builtin.slurp: { src: /etc/pam.d/common-session }
  register: ldap_client_pam_common_session

- name: Abilita SSSD e creazione home in PAM
  ansible.builtin.command: pam-auth-update --enable sssd --enable mkhomedir
  when: "'pam_mkhomedir.so' not in (ldap_client_pam_common_session.content | b64decode)"
  changed_when: true
  notify: Riavvia sssd
```

### templates/sssd.conf.j2

```jinja
[sssd]
config_file_version = 2
services = nss, pam
domains = {{ ldap_client_domain }}

[domain/{{ ldap_client_domain }}]
id_provider = ldap
auth_provider = ldap
ldap_uri = ldaps://{{ ldap_client_server_fqdn }}
ldap_search_base = {{ ldap_client_base_dn }}
ldap_tls_cacert = {{ ldap_client_ca_dest }}
ldap_tls_reqcert = hard
cache_credentials = true
access_provider = simple
simple_allow_groups = {{ ldap_client_allowed_groups }}
```

### handlers/main.yml

```yaml
- name: Riavvia sssd
  ansible.builtin.service: { name: sssd, state: restarted, enabled: true }
```

### Inventory e playbook

```yaml
# inventory.yml
ldap_servers:
  hosts: { ldap: { ansible_host: "{{ ip.ldap_ip }}" } }
ldap_clients:
  hosts: { lb: }        # 'lb' è lo stesso host già in lb_servers (un host, più gruppi)
```

```yaml
# ldap.yml
- name: Configura il server LDAP
  hosts: ldap_servers
  become: true
  roles: [ldap_server]

- name: Configura i client LDAP
  hosts: ldap_clients
  become: true
  roles: [ldap_client]
```

---

## 7. Lezioni DevOps trasversali

- **Idempotenza**: la prova non è creare, è **ri**lanciare e ottenere `changed=0`.
  `ldap_entry` = esistenza; `ldap_attrs state: exact` = attributi (converge sulle modifiche).
- **Segreti fuori dal repo**: password (anzi, **hash**) nel `.env` gitignorato; il
  ruolo conosce solo la variabile, non la sorgente (disaccoppiamento → swap a vault
  = una riga in `group_vars`). `no_log: true` sui task con segreti.
- **debconf preseed**: pre-rispondere alle domande PRIMA dell'install per pacchetti
  interattivi. Agisce solo su install pulita.
- **Handler + notify**: riavvii solo quando qualcosa cambia davvero.
- **`command` con le tre cinture**: (1) esiste un modulo dedicato? (2) `when` per non
  girare a vuoto; (3) `changed_when` per dichiarare l'effetto onestamente.
- **Orchestrazione multi-host**: `slurp` + `delegate_to` + `copy content=` per far
  viaggiare un dato tra host (es. la CA dal server al client).
- **Distruggi-e-ricostruisci**: l'unico modo di provare un ruolo *da zero*. Il
  **disco** è l'OS: per una VM pulita si replica il *volume*, non solo il dominio
  (`tofu apply -replace='libvirt_volume.vm_disk["x"]' -replace='libvirt_domain.vm["x"]'`).
- **Leggere il `plan`/`RECAP`**: `0 to destroy` è il semaforo; `changed` vs `ok`
  racconta la verità (o il falso positivo da indagare).

---

## 8. Gotcha incontrati e soluzioni

- **`apt` non esiste su Arch**: i comandi server vanno sulla VM Ubuntu, non sul PC.
- **Password debconf chiesta in install**: è la password admin LDAP, non SSH.
- **`-replace` del solo dominio non pulisce l'OS**: serve replicare anche il volume disco.
- **Falso positivo "tutto ok"**: se l'install di slapd è `ok` (non `changed`), la VM
  non era pulita e il preseed non è stato consumato.
- **`REMOTE HOST IDENTIFICATION HAS CHANGED`**: nuove chiavi host dopo rebuild →
  `ssh-keygen -R <ip>` (o il play che pulisce `known_hosts`).
- **`python-ldap` mancante**: i moduli `ldap_*` girano *sul target* → `python3-ldap`
  va installato sulla VM (e `python3-cryptography` per crypto).
- **`Object class violation`**: attributo MUST mancante (es. `sn` ereditato da `person`).
- **`ldap_attrs state: exact` su objectClass**: elencare TUTTE le classi, altrimenti
  rimuove quelle non citate.
- **`slappasswd` non c'è su Arch**: generarlo sulla VM via SSH, oppure con openssl.
- **`cannot find name for group ID`**: manca il `posixGroup` con quel `gidNumber`.
- **`ssh_pwauth: false` nel cloud-init**: blocca il login SSH con password → testare
  con `su - utente`.
- **`sssd.conf` non 0600**: SSSD non parte.
- **`ldap_entry` ignora gli attributi**: se la entry esiste, un cambio password nel
  `.env` non si propaga → `ldapdelete` della entry + rilancio (o passare a `ldap_attrs`).
- **Cache SSSD**: dopo modifiche, `sudo sss_cache -E`.

---

## 9. Comandi di verifica

```bash
# Inventory come lo interpreta Ansible
ansible-inventory -i inventory.yml --graph
ansible -i inventory.yml lb -m ping        # raggiungibilità (separa infra da config)

# Sul server
ss -tlnp | grep -E "389|636"
ldapsearch -x -LLL -b "dc=lab,dc=home"
ldapwhoami -x -ZZ   -H ldap://ldap.lab.home  -D "uid=mzelli,ou=people,dc=lab,dc=home" -W
ldapwhoami -x       -H ldaps://ldap.lab.home -D "uid=mzelli,ou=people,dc=lab,dc=home" -W

# Sul client (menu-lb)
getent passwd mzelli        # NSS via SSSD
id mzelli                   # uid/gid/gruppi
getent group devops
su - mzelli                 # auth + authZ + creazione home  (membro di devops -> entra)
su - esterno                # Permission denied  (non in devops: authZ nega in fase account)
sudo sss_cache -E           # svuota la cache SSSD
```

Distinzione dei messaggi di errore:
- `Authentication failure` → fase **auth** (password errata).
- `Permission denied` → fase **account** (autenticato ma non autorizzato).

---

## 10. Cosa resta da fare

- **Irrobustimento del ruolo**: gestire `userPassword` con `ldap_attrs` (`state: exact`)
  invece che con `ldap_entry`, così un cambio di hash nel `.env` si propaga da solo.
- **`ansible-vault`**: sostituire il `.env` per i segreti (cambia solo la riga in
  `group_vars/ldap_servers.yml`, da `lookup('env')` al blocco `!vault`).
- **Verso Active Directory**: AD = questo modello + **Kerberos** (autenticazione a
  ticket invece del bind), **DNS** (service discovery), e l'**unificazione** di
  `posixGroup`/`groupOfNames` in un unico oggetto-gruppo. SSSD è già lo stesso
  strumento usato per unire Linux ad AD.

---

*Tutto realizzato in rete locale, solo software open-source, su un branch dedicato
(`feature/ldap-base`). Dalla teoria a un mini sistema di identità centralizzata
funzionante e riproducibile come codice.*

## APPUNTI DEI COMANDI IN MACCHINA PER LDAP


# installazione
sudo apt update
sudo apt install -y slapd ldap-utils #slapd è il servers, ldap utils sono i client da riga di comando
password: topina123
sudo dpkg-reconfigure slapd
Rispondi così, e ti spiego cosa significa ogni risposta:

"Omit OpenLDAP server configuration?" → No. (Vogliamo configurarlo, non saltarlo.)
"DNS domain name:" → lab.home. Questo è il punto chiave: il dominio viene tradotto nel tuo base DN, cioè dc=lab,dc=home. Uso .home e non .local per la ragione di cui parlammo (.local collide con mDNS).
"Organization name:" → Lab (o quello che vuoi). Diventa l'attributo o: della entry radice.
"Administrator password:" → scegline una e ricordala: è la password con cui ti autenticherai come cn=admin,dc=lab,dc=home, l'utente che può scrivere nell'albero. Te la chiederà a ogni ldapadd/ldapmodify.
"Database backend:" → MDB (è LMDB, il backend di default moderno e veloce).
"Remove database when slapd is purged?" → No (così disinstallando non perdi i dati per sbaglio).
"Move old database?" → Yes (sposta il vecchio dc=nodomain e mette il nuovo al suo posto).

# controlli
Prima controlla che il server sia su e in ascolto (riusi ss, dai tuoi studi di networking — LDAP sta sulla porta 389):
systemctl status slapd
ss -tlnp | grep 389
Ora la prima vera query LDAP. Leggi tutto il sottoalbero a partire dalla radice:
ldapsearch -x -LLL -H ldap://localhost -b "dc=lab,dc=home"
-x → simple bind, cioè autenticazione semplice. Qui senza credenziali = bind anonimo: le ACL di default permettono a chiunque di leggere gran parte dell'albero.
-LLL → output LDIF pulito, senza commenti e righe di versione.
-H ldap://localhost → l'URI del server da contattare.
-b "dc=lab,dc=home" → la base della ricerca: da dove parte. (Più avanti aggiungeremo lo scope e i filtri.)
Per vedere lo stesso contenuto "dal di dentro", bypassando rete e ACL, c'è anche:
sudo slapcat

# aggiunta di 2 unità
aggiunta di due unità organizzavite.
il file:
#file: 01-struttura.ldif
dn: ou=people,dc=lab,dc=home
objectClass: organizationalUnit
ou: people

dn: ou=groups,dc=lab,dc=home
objectClass: organizationalUnit
ou: groups

Ogni entry inizia con la sua dn: e le entry sono separate da una riga vuota. Quella riga vuota è sintatticamente significativa: separa due record.
ou=people,dc=lab,dc=home si legge da sinistra: la entry people, figlia di dc=lab,dc=home. Stai appendendo un ramo al tronco.
objectClass: organizationalUnit è ciò che rende people un contenitore valido e le impone l'attributo ou.

bind autenticato come admin, perché scrivere richiede permessi:
ldapadd -x -D "cn=admin,dc=lab,dc=home" -W -f 01-struttura.ldif

-x → simple bind
-D "cn=admin,dc=lab,dc=home" → chi sei: il DN dell'admin
-W → ti chiede la password LDAP in modo interattivo (quella che hai impostato prima — non quella di SSH)
-f 01-struttura.ldif → il file da caricare

# lettura dell'albero

Rileggi l'albero, e stavolta giochiamo con lo scope della ricerca:
tutto il sottoalbero (default: scope "sub")
ldapsearch -x -LLL -H ldap://localhost -b "dc=lab,dc=home"

solo i figli DIRETTI della radice (scope "one") -> devono uscire ou=people e ou=groups
ldapsearch -x -LLL -H ldap://localhost -b "dc=lab,dc=home" -s one

solo la entry indicata (scope "base") -> NON devono uscire ou=people e ou=groups
ldapsearch -x -LLL -H ldap://localhost -b "dc=lab,dc=home" -s base

# aggiunta utente

ldapadd -x -D "cn=admin,dc=lab,dc=home" -W -f /etc/ldap/ldif/03-utente.ldif

ldif# file: 03-utente.ldif
dn: uid=mzelli,ou=people,dc=lab,dc=home
objectClass: inetOrgPerson
uid: mzelli
cn: Martina Zelli
sn: Zelli
mail: mzelli@lab.home
userPassword: Password123

# must e may di una classe

ricerca dei MUST e MAY di una classe:
ldapsearch -x -LLL -o ldif-wrap=no -H ldap://localhost -s base -b cn=subschema objectClasses \
  | grep "'organizationalUnit'"

Se preferisci leggere i file sorgente invece di interrogare il server:
ls /etc/ldap/schema/
less /etc/ldap/schema/core.ldif        # qui dentro trovi organizationalUnit e person

# ricerca da admin
Esempio ricerca da admin:
ldapsearch -x -D "cn=admin,dc=lab,dc=home" -W -LLL -H ldap://localhost \
  -b "dc=lab,dc=home" "(uid=mzelli)" userPassword

# password in SSHA
La correzione: hashing
In LDAP le password si memorizzano hashate. slapd supporta vari schemi; lo standard ragionevole è {SSHA} (SHA con salt). C'è un comando apposta per generarlo:
slappasswd -h {SSHA}
Ti chiede la nuova password due volte e stampa qualcosa come:
{SSHA}xQ9...stringa...==
Quel prefisso {SSHA} è importante: dice a slapd con quale algoritmo confrontare al momento del bind. Copia tutta la stringa, ti serve ora.
{SSHA}EaVpFtxLKDTt8qJQnkm97oz4tIiT+/Ah

# modifica di un attributo esistente
Modificare un attributo esistente: ldapmodify
modifichi un attributo di una entry che esiste già, e per farlo c'è una sintassi LDIF nuova — quella delle modifiche. Crea il file:
ldif# file: 04-fix-password.ldif
dn: uid=mzelli,ou=people,dc=lab,dc=home
changetype: modify
replace: userPassword
userPassword: {SSHA}INCOLLA_QUI_LA_STRINGA_DI_slappasswd
La grammatica nuova, riga per riga:

dn: → quale entry tocchi.
changetype: modify → stai modificando (non aggiungendo). Senza questo, ldapadd proverebbe a creare e fallirebbe perché l'entry esiste già.
replace: userPassword → l'operazione: sostituisci tutti i valori di userPassword. (Le alternative sono add: per aggiungere un valore e delete: per rimuoverlo — utili su attributi multi-valore.)
la riga userPassword: ... → il nuovo valore.

sudo vim /etc/ldap/ldif/04-fix-password.ldif
ldapmodify -x -D "cn=admin,dc=lab,dc=home" -W -f /etc/ldap/ldif/04-fix-password.ldif

# verifica who am i?
 fai autenticare l'utente con se stesso (verifica)
ldapwhoami -x -D "uid=mzelli,ou=people,dc=lab,dc=home" -W

# recap
Ricapitolando cosa padroneggi ora — e questa lista è la spina dorsale del tuo ldap-runbook.md:

Struttura: DIT, base DN, DN/RDN, le ou come contenitori.
Schema: objectClass, MUST/MAY, ereditarietà via SUP, e l'errore Object class violation che sai diagnosticare.
Operazioni: ldapadd (creare), ldapmodify con changetype/replace (modificare), ldapsearch con scope (base/one/sub) e filtri.
Identità e sicurezza: bind anonimo vs autenticato, ACL che filtrano per identità, hashing {SSHA}, e l'autenticazione vera con ldapwhoami. Più la lettura dello schema vivo via cn=subschema.

## TLS

# Credential Autority
Che cos'è una CA (Certification Authority)?
In termini semplici, una CA (Certification Authority) è un ente terzo, considerato "di fiducia" (trusted third party), che si occupa di verificare l'identità di soggetti (persone, server, organizzazioni) e di emettere certificati digitali.
Il compito della CA è garantire che una chiave pubblica appartenga effettivamente al proprietario dichiarato. Senza una CA, chiunque potrebbe creare una chiave e fingersi un server LDAP o un sito web (attacco di tipo Man-in-the-Middle).

Differenza tra CA Pubblica e CA Privata (Self-Signed)
CA Pubblica: È un'organizzazione riconosciuta a livello globale (come DigiCert, Let's Encrypt, Sectigo). I loro certificati "radice" (root) sono pre-installati in quasi tutti i sistemi operativi eUn appunto sul tuo s_client browser.

Vantaggio: Quando il tuo client LDAP (o browser) si connette a un server certificato da una CA pubblica, si fida automaticamente del certificato perché il software "conosce" e riconosce la CA.

CA Privata (o Self-Signed): È un'infrastruttura creata internamente (spesso usando strumenti come OpenSSL).

Svantaggio: Nessuno, al di fuori della tua rete privata, si fiderà del certificato. Dovrai distribuire manualmente il certificato "Root CA" su ogni client (computer o server) che deve connettersi al servizio LDAP, altrimenti riceverai errori di "certificato non attendibile".

In un lab non hai una CA pubblica (Let's Encrypt richiede un dominio pubblico, qui non c'entra). La pratica standard per infrastruttura interna è creare una CA privata tua e firmarci il certificato del server. Sulla VM:
mkdir -p ~/ca && cd ~/ca

#1) Chiave + certificato della CA (la radice della fiducia), valida 10 anni
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -kUn appunto sul tuo s_clientey ca.key -out ca.crt -subj "/O=Lab/CN=Lab Root CA"

#2) Chiave privata del server LDAP
openssl genrsa -out ldap.key 2048

#3) Richiesta di certificato (CSR) per il nome del server
openssl req -new -key ldap.key -out ldap.csr -subj "/O=Lab/CN=ldap.lab.home"

#4) File con i SAN (Subject Alternative Names): i nomi/IP per cui il cert è valido
cat > ldap.ext <<'EOF'
subjectAltName = DNS:ldap.lab.home, DNS:ldap.local, IP:192.168.1.76
EOF

#5) La CA firma la CSR -> nasce il certificato del server
openssl x509 -req -in ldap.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 825 -out ldap.crt -extfile ldap.ext

a questo punto dovremmo avere questi file creati:
ls ~/ca
ca.crt  ca.key  ca.srl  ldap.crt  ldap.csr  ldap.ext  ldap.key

# gestione dei permessi dei file.

Posizionare i file con i permessi giusti
Questo è il punto #1 che rompe TLS: slapd gira come utente openldap, quindi deve poter leggere la chiave privata.
sudo cp ca.crt  /etc/ssl/certs/lab-ca.crt
sudo cp ldap.crt /etc/ldap/ldap.crt
sudo cp ldap.key /etc/ldap/ldap.key

sudo chgrp openldap /etc/ldap/ldap.key       # il gruppo openldap può leggere la chiave
sudo chmod 0640 /etc/ldap/ldap.key           # proprietario rw, gruppo r, altri niente
sudo chmod 0644 /etc/ldap/ldap.crt /etc/ssl/certs/lab-ca.crt

Metto i file sotto /etc/ldap/ e /etc/ssl/certs/ di proposito: sono percorsi che il profilo AppArmor di slapd già consente in lettura. Se li mettessi in una cartella a caso, AppArmor potrebbe bloccarli silenziosamente.

# dare la posiziomne dei file a slapd
Crea il file con le modifiche all'albero di configurazione:

ldif# file: ~/ca/certinfo.ldif
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

Grammatica LDIF nuova: il trattino - su una riga da solo separa più operazioni sulla stessa entry. Qui stai facendo tre replace sull'unica entry cn=config. Uso replace (non add) perché funziona sia se gli attributi esistono già sia se no.

Applica — e nota la sintassi di autenticazione completamente diversa:
sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f ~/ca/certinfo.ldif
-Y EXTERNAL -H ldapi:/// = "autenticami via SASL EXTERNAL sul socket locale". Niente -D, niente -W: la tua identità è quella di root (per questo sudo). Vedrai un SASL username: gidNumber=0+uidNumber=0,...,cn=auth — è root mappato sull'identità LDAP.
A questo punto StartTLS è già attivo, senza riavviare slapd.

# far fidare il client della tua CA
Il client (per ora la VM stessa) deve (a) fidarsi della tua CA e (b) saper risolvere ldap.lab.home.

#(a) il client LDAP si fida della nostra CA
echo "TLS_CACERT /etc/ssl/certs/lab-ca.crt" | sudo tee -a /etc/ldap/ldap.conf

#(b) il nome ldap.lab.home punta alla VM
echo "192.168.1.76  ldap.lab.home ldap.local" | sudo tee -a /etc/hosts

Il perché di (a): TLS funziona per catena di fiducia. Il certificato del server è firmato dalla tua CA; il client accetta il server solo se conosce e si fida di quella CA. TLS_CACERT gli dice qual è. (Quando un domani interrogherai dal tuo Arch, copierai lab-ca.crt lì e farai lo stesso — la CA è il pezzo che distribuisci ai client.)

# verifica
StartTLS sulla 389 (il -ZZ impone la promozione a TLS, fallisce se non riesce):
ldapwhoami -x -ZZ -H ldap://ldap.lab.home -D "uid=mzelli,ou=people,dc=lab,dc=home" -W
Se risponde dn:uid=mzelli,ou=people,dc=lab,dc=home, hai appena rifatto l'autenticazione di prima ma cifrata.

# abilitazione della porta 636 e riavvio del servizio
Poi abilita anche LDAPS sulla 636 (questo invece richiede un riavvio):

sudo sed -i 's|^SLAPD_SERVICES=.*|SLAPD_SERVICES="ldap:/// ldapi:/// ldaps:///"|' /etc/default/slapd

il comando, tradotto in italiano: "con i privilegi di root, modifica sul posto il file /etc/default/slapd, sostituendo la riga che inizia con SLAPD_SERVICES= con questa nuova riga".
/etc/default/slapd è un file di sistema, scrivibile solo da root → serve sudo. È il file dove Debian/Ubuntu mettono le opzioni di avvio del demone slapd (non la sua configurazione interna, che invece sta in cn=config). Quando il servizio parte, lo script di avvio legge questo file e usa la variabile SLAPD_SERVICES per decidere su quali "porte/socket" slapd resta in ascolto. È proprio quella stringa che diventa l'argomento -h che hai visto in slapd -h "ldap:/// ldapi:///".
Quindi: i tre URI dentro SLAPD_SERVICES sono i punti di ascolto. ldap:/// = porta 389 in chiaro/StartTLS; ldapi:/// = socket Unix locale; ldaps:/// = porta 636 cifrata. Aggiungendo ldaps:/// hai detto a slapd "ascolta anche sulla 636" — ed è esattamente perché, dopo il restart, ss ti ha mostrato la 636 comparire.

(un comando piu sicuro sarebbe così:
#1) Backup automatico: -i.bak salva l'originale come /etc/default/slapd.bak
sudo sed -i.bak 's|^SLAPD_SERVICES=.*|SLAPD_SERVICES="ldap:/// ldapi:/// ldaps:///"|' /etc/default/slapd
#2) Verifica DOPO: controlla sempre che la riga sia davvero come la vuoi
grep SLAPD_SERVICES /etc/default/slapd)

sudo systemctl restart slapd
ss -tlnp | grep -E '389|636'        # ora devi vedere anche la 636
ldapwhoami -x -H ldaps://ldap.lab.home -D "uid=mzelli,ou=people,dc=lab,dc=home" -W

E se vuoi vedere il certificato che viaggia sul filo:
openssl s_client -connect ldap.lab.home:636 -showcerts </dev/null | head -20

Un appunto sul tuo s_client

Tornando al verify error:num=19: se vuoi vederlo sparire e confermare che la catena è valida quando il client conosce la CA, passa la tua CA a openssl:
bashopenssl s_client -connect ldap.lab.home:636 -CAfile /etc/ssl/certs/lab-ca.crt </dev/null 2>/dev/null | grep -i "verify"
Dovresti leggere Verify return code: 0 (ok). È la prova, lato strumento generico, di ciò che i tuoi ldapwhoami già dimostravano: con la CA giusta in mano, la fiducia si chiude.

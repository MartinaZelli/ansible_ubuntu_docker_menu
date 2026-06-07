# Progetto: Infrastruttura Distribuita FastAPI & MySQL

Questo repository contiene l'automazione Ansible per il deployment di un'architettura scalabile composta da un database MySQL, molteplici nodi applicativi FastAPI e un bilanciatore di carico HAProxy, il tutto orchestrato su server Ubuntu 24.04 LTS.

## Prerequisiti
Prima di iniziare, assicurati che la macchina di controllo (il tuo computer) soddisfi i seguenti requisiti:
* **Ansible**: Installato e aggiornato (versione > 2.10 consigliata).
* **Python**: Python 3.x installato sulla macchina di controllo.
* **Collezioni Ansible**: Necessario installare le dipendenze:
  `ansible-galaxy collection install community.general`
* **SSH**: Accesso SSH configurato verso tutti i server target (menu-app, menu-app-2, menu-db, menu-lb).
* **Chiave Privata**: La tua chiave SSH privata deve essere presente sul PC di controllo e il percorso configurato nel file .env.

## Architettura del Sistema
Il progetto adotta un approccio a micro-servizi isolati:
* **Database**: Container MySQL 8.0 isolato.
* **Application Tier**: Nodi FastAPI distribuiti in un gruppo di scaling (`app_servers`).
* **Load Balancing**: Frontend HAProxy che gestisce il traffico verso le istanze applicative e verifica la presenza attiva del DB.

## Tech Stack & Componenti
* **Automazione**: Ansible (con `docker_compose_v2` e moduli `ufw`).
* **Containerizzazione**: Docker & Docker Compose v2.
* **Applicazione**: FastAPI (repository: `https://github.com/MartinaZelli/menu_v2.0.git`)
* **Database**: MySQL 8.0
* **Load Balancer**: HAProxy (installazione nativa su OS).
* **Target OS**: Ubuntu 24.04 LTS.

## Configurazione Operativa
PIl progetto è ora interamente configurato tramite variabili d'ambiente.

### 1. Preparazione dell'Ambiente
Crea un file `.env` nella root del progetto basandoti sul file `.env.example`.
Il sistema legge automaticamente le variabili tramite lo script `avvio_playbook.sh`.

### 2. Struttura delle Variabili
* **.env**: Centralizza tutte le configurazioni (credenziali DB, IP, porte, token Git, etc.).
* **group_vars/all.yml**: Contiene i default per l'applicazione e le strutture dati dei gruppi.

### 3. Procedura di Avvio
Per eseguire l'automazione, utilizza lo script `avvio_playbook.sh`, che automatizza l'esportazione delle variabili d'ambiente e l'integrazione con il Vault:

1. Rendi lo script eseguibile: `chmod +x avvio_playbook.sh`
2. Lancia il deployment completo: `./avvio_playbook.sh`

### 4. Modularità e Tag
Puoi eseguire il deployment parziale per testare singole componenti passando i tag allo script:
* **Solo Database**: `./avvio_playbook.sh -t db`
* **Solo Applicazione**: `./avvio_playbook.sh -t app`
* **Solo Load Balancer**: `./avvio_playbook.sh -t lb`

## Struttura del Progetto
```
.
├── ansible.cfg                  # Configurazione globale di Ansible
├── avvio_servizi.sh             # Script Bash per avviare il deploy
├── avvio_servizi.yml            # Playbook principale di installazione
├── cleanup_servizi.sh           # Script Bash per avviare la pulizia
├── cleanup_servizi.yml          # Playbook principale di rimozione risorse
├── group_vars
│   └── all.yml                  # Variabili globali condivise tra i gruppi
├── inventory.yml                # Inventario degli host e dei gruppi
├── README.md                    # Documentazione del progetto
└── roles
    ├── costruzione_progetto     # Ruolo per il deploy delle risorse
    │   ├── handlers
    │   │   └── main.yml         # Gestione riavvio servizi (es. reload HAProxy)
    │   ├── tasks
    │   │   ├── database.yml     # Setup container MySQL e volumi
    │   │   ├── load_balancer.yml# Configurazione HAProxy
    │   │   ├── main.yml         # Punto di ingresso del ruolo
    │   │   ├── progetto.yml     # Setup Git e applicazione
    │   │   └── sistema.yml      # Setup pacchetti base e Docker
    │   └── templates
    │       ├── backend_app.cfg.j2   # Template backend app per HAProxy
    │       ├── backend_db.cfg.j2    # Template backend DB per HAProxy
    │       └── haproxy_base.cfg.j2  # Template base HAProxy
    └── project_cleanup          # Ruolo per la pulizia delle risorse
        ├── handlers
        │   └── main.yml         # Handler per il riavvio post-pulizia
        └── tasks
            └── main.yml         # Logica di rimozione sicura (stat + absent)
```
## Procedure di Gestione
Il progetto offre un secondo workflow gestito tramite script Bash:

* **Cleanup (Pulizia)**: Utilizza `./cleanup_servizi.sh` per rimuovere i servizi in modo sicuro e controllato.

### 3. Procedura di Avvio Cleanup
Per eseguire l'automazione, utilizza lo script `cleanup_servizi.sh`, che automatizza l'esportazione delle variabili d'ambiente e l'integrazione con il Vault:

1. Rendi lo script eseguibile: `chmod +x cleanup_servizi.sh`
2. Lancia il deployment completo: `./cleanup_servizi.sh`

## Modulo di Cleanup (`project_cleanup`)
È stata implementata una procedura dedicata per la rimozione dei servizi, progettata per essere idempotente e sicura:

* **Rimozione Risorse**: Elimina container Docker, volumi dati e directory di progetto.
* **Cleanup HAProxy**: Rimuove chirurgicamente i backend dai file di configurazione (`haproxy.cfg`) utilizzando i marker definiti, senza compromettere il resto della configurazione.
* **Firewall (UFW)**: Ripulisce automaticamente le regole UFW create durante la fase di avvio.
* **Resilienza**: Il playbook utilizza verifiche preventive (`stat`) per ogni risorsa. Se un file o una directory è già stato rimosso, il playbook salta il task senza restituire errori, garantendo una procedura di pulizia sempre completabile.

## Comandi Utili per Debug e Manutenzione

* **Debug Variabili**
  Se hai il dubbio che una variabile non venga letta correttamente, usa il modulo `debug`:
  - Debug variabile specifica:
    `ansible -i inventory.yml -m debug -a "var=db_conn.host" db`

* **Simulazione (Dry-Run)**
  - Verifica modifiche senza applicarle: `./avvio_playbook.sh --check`

* **Visualizzazione Inventario**
  - Grafico gruppi: `ansible-inventory -i inventory.yml --graph`

* **Accedere ad una Vm**
  - comando generico: `ssh -i /path/to/private_key user@remote_host`

* **Dare un comando diretto ad una Vm**
  - comando generico: `ssh -i /path/to/private_key user@remote_host "command_to_execute"`














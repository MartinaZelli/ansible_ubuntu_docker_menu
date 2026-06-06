```markdown
# Progetto: Infrastruttura Distribuita FastAPI & MySQL

Questo repository contiene l'automazione Ansible per il deployment di un'architettura scalabile composta da un database MySQL, molteplici nodi applicativi FastAPI e un bilanciatore di carico HAProxy, il tutto orchestrato su server Ubuntu 24.04 LTS.

## Architettura del Sistema
Il progetto adotta un approccio a micro-servizi isolati:
* **Database**: Container MySQL 8.0 isolato.
* **Application Tier**: Nodi FastAPI distribuiti in un gruppo di scaling (`app_servers`).
* **Load Balancing**: Frontend HAProxy che gestisce il traffico verso le istanze applicative.

## Struttura del Progetto
La gerarchia dei file è organizzata per massimizzare la modularità e la riusabilità dei ruoli:

```text
.
├── ansible.cfg              # Configurazione Ansible (punta a inventory.yml)
├── avvio_servizi.yml        # Orchestratore principale
├── inventory.yml            # Definizione dei nodi e dei gruppi (app, db, lb)
├── group_vars/
│   └── all.yml              # Variabili globali e configurazioni dei servizi
└── roles/
    └── progetto_menu/
        ├── handlers/        # Gestione riavvii (Docker, HAProxy)
        ├── tasks/           # Logica suddivisa per ruolo (sistema, db, app, lb)
        └── templates/       # Template Jinja2 per la config di HAProxy
```

## Setup e Deploy
Il deployment è modulare. Puoi eseguire l'intero setup o filtrare per componente utilizzando i **tag**:

* **Esecuzione completa**: `ansible-playbook avvio_servizi.yml`
* **Solo Database**: `ansible-playbook avvio_servizi.yml -t db`
* **Solo Applicazione**: `ansible-playbook avvio_servizi.yml -t app`
* **Solo Load Balancer**: `ansible-playbook avvio_servizi.yml -t lb`

## Tech Stack & Componenti
* **Automazione**: Ansible (con `docker_compose_v2` e moduli `ufw`).
* **Containerizzazione**: Docker & Docker Compose v2.
* **Applicazione**: FastAPI (repository: `https://github.com/MartinaZelli/menu_v2.0.git`)
* **Database**: MySQL 8.0
* **Load Balancer**: HAProxy (installazione nativa su OS).
* **Target OS**: Ubuntu 24.04 LTS.

## Prerequisiti
* **Connettività**: Accesso SSH tramite chiave privata (`~/.ssh/id_archvm`).
* **Dipendenze**: Python 3 e i moduli `docker` e `community.general` installati sulla macchina di controllo (control node).
* **Variabili**: Il file `group_vars/all.yml` contiene le configurazioni critiche (credenziali DB, percorsi di installazione e lista pacchetti) che devono essere mantenute aggiornate.

## Note di Refactoring
* **Modularità**: La logica di setup è stata suddivisa in file di task dedicati, richiamati centralmente dal `main.yml` del ruolo tramite `include_tasks`.
* **Sicurezza**: Implementate policy di firewall restrittive (default `deny`) tramite UFW.
* **Configurazione**: Il file `.env` dell'applicazione viene generato dinamicamente per ogni nodo applicativo in fase di setup.
* **Scalabilità**: Il sistema è pronto per aggiungere nuovi nodi applicativi semplicemente aggiornando l'inventario.

## Note Operative
Il deployment garantisce l'isolamento dei componenti: il database e le istanze applicative girano su macchine distinte. L'intera configurazione è gestita in modo dichiarativo tramite il file `group_vars/all.yml`.
















# Progetto: Automazione Deployment - Menu FastAPI & MySQL

Questo repository contiene l'infrastruttura Ansible per l'automazione del deployment di un'applicazione FastAPI e il relativo database MySQL su server Ubuntu 24.04 LTS.

## Struttura del Progetto
La gerarchia dei file è organizzata per massimizzare la modularità e la riusabilità dei ruoli:

```text
.
├── avvio_servizi.yml            # Orchestratore principale dei play
├── group_vars
│   └── all.yml                  # Variabili globali e credenziali
├── inventory.yml                # Definizione dei nodi (app e db)
├── README.md                    # Documentazione del progetto
└── roles
    └── progetto_menu
        ├── handlers
        │   └── main.yml         # Gestione riavvii servizi
        └── tasks
            ├── database.yml     # Task per il container MySQL
            ├── main.yml         # Inizializzazione ruoli
            ├── progetto.yml     # Setup Git e deploy FastAPI
            └── sistema.yml      # Configurazione base sistema

```

## Architettura e Workflow
Il progetto utilizza un approccio modulare tramite **Ansible Roles**. Il processo di deployment è suddiviso in tre fasi principali eseguite tramite `avvio_servizi.yml`:

1.  **Inizializzazione (Sistema)**: Configurazione comune su tutti i nodi (installazione Docker, Git, Python dependencies) e configurazione dell'utente `ubuntu`.
2.  **Database (MySQL)**: Setup di un container Docker dedicato sulla macchina `menu-db`. Il database viene inizializzato con le credenziali definite in `group_vars/all.yml`.
3.  **Applicazione (FastAPI)**: Deployment dell'applicazione sulla macchina `menu-app`. Include il download del codice sorgente da Git, la creazione dinamica del file `.env` per la connessione al database remoto e l'avvio del servizio tramite `docker-compose`.

## Tech Stack
* **Automazione**: Ansible
* **Containerizzazione**: Docker & Docker Compose v2
* **Applicazione**: FastAPI (repository: `https://github.com/MartinaZelli/menu_v2.0.git`)
* **Database**: MySQL 8.0
* **Target OS**: Ubuntu 24.04 LTS

## Dipendenze e Requisiti
* **Connettività**: Accesso SSH tramite chiave privata (`~/.ssh/id_archvm`).
* **Variabili**: Il file `group_vars/all.yml` contiene le configurazioni critiche (credenziali DB, percorsi di installazione e lista pacchetti) che devono essere mantenute aggiornate.
* **Storage**: I dati del database sono persistiti tramite il volume Docker `db_data`.

## Struttura del Progetto
* `avvio_servizi.yml`: Orchestratore principale dei play.
* `inventory.yml`: Definizione dei gruppi `app_servers` e `db_servers`.
* `group_vars/all.yml`: Variabili globali di configurazione.
* `roles/progetto_menu/`: Contiene la logica specifica suddivisa in:
    * `tasks/`: Script di installazione (sistema, DB, applicazione).
    * `handlers/`: Gestione dei riavvii dei servizi (es. Riavvia Docker).

## Note Operative
Il deployment è isolato: il container applicativo e il database girano su macchine distinte per garantire modularità. Il file `.env` per l'applicazione viene generato automaticamente in fase di setup utilizzando i parametri di connessione al database remoto definiti nelle variabili di gruppo.

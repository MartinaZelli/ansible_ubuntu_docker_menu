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

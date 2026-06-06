```markdown
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
* **Load Balancing**: Frontend HAProxy che gestisce il traffico verso le istanze applicative.

## Tech Stack & Componenti
* **Automazione**: Ansible (con `docker_compose_v2` e moduli `ufw`).
* **Containerizzazione**: Docker & Docker Compose v2.
* **Applicazione**: FastAPI (repository: `https://github.com/MartinaZelli/menu_v2.0.git`)
* **Database**: MySQL 8.0
* **Load Balancer**: HAProxy (installazione nativa su OS).
* **Target OS**: Ubuntu 24.04 LTS.

## Configurazione Operativa
Per avviare correttamente il progetto, è necessario seguire la configurazione delle variabili e la gestione della sicurezza tramite Ansible Vault.

### 1. Preparazione dell'Ambiente
Crea i seguenti file nella root del progetto:

* **.env**: Definisce le variabili di ambiente per lo script di avvio.
  GIT_TOKEN=tuo_token_github_qui
  PRIVATE_KEY_PATH=~/.ssh/la_tua_chiave_ssh

* **.vault_pass**: Contiene la password per il Vault (imposta i permessi con chmod 600).

### 2. Struttura delle Variabili
* **group_vars/all.yml**: Contiene le variabili pubbliche (host, porta, path).
* **group_vars/db_servers.yml** (Criptato): Contiene i segreti (pass, root_pass, volume_path).

Per modificare i segreti criptati:
ansible-vault edit group_vars/db_servers.yml
Per decriptare i segreti criptati:
ansible-vault decrypt group_vars/db_servers.yml
Per criptare i segreti:
ansible-vault encrypt group_vars/db_servers.yml

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
.
├── ansible.cfg                 # Configurazione globale di Ansible
├── avvio_playbook.sh           # Script bash per avviare il playbook con supporto tag
├── avvio_servizi.yml           # Playbook principale che orchestra i ruoli
├── example_files
│   └── db_servers.yml.example  # Esempio di variabili segrete (non criptato)
│   └── .env.example            # Esempio di variabili d'ambiente
│   └── .vault_pass.example     # Esempio di file di password
├── group_vars
│   ├── all.yml                 # Variabili di configurazione (host, porta, path)
│   └── db_servers.yml          # Credenziali criptate (Vault - pass, root_pass)
├── inventory.yml               # Inventario degli host (gruppi app, db, lb)
├── README.md                   # Documentazione operativa del progetto
└── roles
    └── progetto_menu           # Ruolo principale di automazione
        ├── handlers
        │   └── main.yml        # Gestione riavvio servizi (Docker/HAProxy)
        ├── tasks
        │   ├── database.yml    # Setup container MySQL e volumi
        │   ├── load_balancer.yml# Configurazione HAProxy
        │   ├── main.yml        # Inizializzazione ruoli e inclusioni
        │   ├── progetto.yml    # Setup Git, Python e generazione .env
        │   └── sistema.yml     # Setup Docker, pacchetti e utenti
        └── templates
            └── haproxy.cfg.j2  # Template per la configurazione del bilanciatore

## Troubleshooting e Note Operative
* Per verificare che le variabili siano lette correttamente:
  ansible-inventory --list --vault-password-file=.vault_pass
* Debug: Per vedere i dettagli di un errore, usa la verbosità elevata:
  ./avvio_playbook.sh -vvv -t [tag]
* Verifica Stato: Controlla se i container sono attivi su tutti i nodi:
  ansible -i inventory.yml -m shell -a "docker ps" all
* Nota di Distruzione: Attualmente non è presente un task di 'destroy'. Per rimuovere i servizi, procedere manualmente sui nodi (es. docker stop/rm).

### Comandi Utili per Debug e Manutenzione

* Controllo Log dei Container:
Se il playbook termina con successo ma l'applicazione non risponde, controlla i log del container specifico:
  - Log DB: ansible -i inventory.yml -m shell -a "docker logs mysql_db" menu-db
  - Log App: ansible -i inventory.yml -m shell -a "docker logs <nome_container>" menu-app

* Verifica Connettività di Rete:
  - Testa HAProxy: ansible -i inventory.yml -m shell -a "curl -I http://localhost" menu-lb

* Test Variabili se hai il dubbio che una variabile non venga letta correttamente, usa il modulo `debug` per interrogarla al volo:
  - Debug variabile specifica: ansible -i inventory.yml -m debug -a "var=db_conn.host" menu-db --vault-password-file=.vault_pass

* Pulizia Forzata (Riavvio dei servizi) in caso di modifiche di configurazione dove è necessario il riavvio forzato:
  - ansible-playbook avvio_servizi.yml -t app --extra-vars "restart_services=true"

* Simulazione (Dry-Run):
  - Verifica modifiche senza applicarle: ./avvio_playbook.sh --check

* Visualizzazione Inventario:
  - Grafico gruppi: ansible-inventory --graph

* Verifica Connessione:
  - Ping su tutti gli host: ansible -i inventory.yml -m ping all









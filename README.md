# Attivazione Bolla: replica asincrona ordinata per criticita applicativa

La soluzione ricrea Virtual Machine (VM), server virtuali Azure, in un ambiente di Disaster Recovery (DR), cioe di ripristino. Azure Functions esegue PowerShell 7.6 sul piano Flex Consumption. Il codice deriva da [stefze/Attivazione-Bolla](https://github.com/stefze/Attivazione-Bolla).

**Questo README descrive `feature/async-session-id-csv-log`, derivato da `feature/async-session-id`.** Git non permette il nome `feature/async-session-id/csv-log` mentre esiste il ramo padre: il nome alternativo mantiene intatto il padre. Questa versione aggiunge criticita, acronimo e report compatibile con il tracciato cliente. Restano routing multisubscription e copia diretta dei managed disk, dischi gestiti da Azure, senza snapshot intermedi. Uno snapshot e una copia puntuale conservata come risorsa separata; questo flusso non ne crea, legge o riusa.

**Per condurre la prova con il cliente:** seguire la [guida operativa passo per passo](docs/guida-test-cliente.md). Include uso di tutte e tre le funzioni, comandi, risultati attesi, gestione degli errori e resoconto aggiornato, senza richiedere un nuovo deployment se l'app e gia pronta.

## Quale architettura viene distribuita

Un **session identifier (`sessionId`)** e una stringa UUID, Universally Unique Identifier, che il client genera prima della richiesta. Identifica una singola attivazione e tutte le VM del suo elenco. Il server non lo genera e non usa l'identificatore dell'esecuzione del runtime al suo posto. Richiede il formato `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, diverso dall'UUID vuoto, e lo normalizza in minuscolo.

Azure Blob Storage conserva file privati. Azure Queue Storage conserva messaggi che un esecutore legge successivamente. La sessione rimane nello storage fino alla cancellazione autorizzata: non e prevista una scadenza automatica.

Le due Application Programming Interface (API), interfacce HTTP chiamate dal client, e la funzione di elaborazione hanno queste responsabilita:

| Quale componente esegue il lavoro | Quale responsabilita ha |
|---|---|
| `Invoke-DRReplication`, chiamata HTTP POST. | Valida richiesta e CSV, registra la sessione, accoda un messaggio e risponde senza eseguire la replica. |
| `Process-DRSession`, attivata dalla coda. | Acquisisce la sessione, controlla i prerequisiti di tutte le VM e, soltanto se passano, esegue la replica. Non espone un endpoint HTTP. |
| `Get-DRStatus`, chiamata HTTP GET o POST. | Legge esclusivamente lo stato persistente del `sessionId` richiesto. Non avvia risorse e non sceglie log di altre sessioni. |

HTTP, Hypertext Transfer Protocol, e il protocollo delle chiamate del client. Il codice 202 significa che il lavoro e stato accettato, non che la replica sia riuscita.

```text
Client: genera sessionId e carica il CSV
  |
  | HTTPS privato + function key
  v
Invoke-DRReplication
  |-- Blob privato: legge CSV, conserva richiesta e stato
  |-- Queue privata: invia { schemaVersion: 1, sessionId }
  |<- Queue conferma HTTP 201
  `-> Client: HTTP 202, sessionId, statusUrl

Queue privata
  `-> Process-DRSession
        |-- Blob privato: legge la richiesta originale
        |-- Verifica tutti i prerequisiti DR
        |-- Copia dischi, crea NIC/VM, collega backend pool
        `-- Blob privato: aggiorna stato ed esiti per VM

Client -> Get-DRStatus?sessionId=... -> stato di quella sessione
```

Una Network Interface (NIC) e la scheda di rete della VM. Un backend pool e l'elenco di destinazioni di un Load Balancer, il servizio che distribuisce traffico.

### Come vengono usate rete e identita

Una User-Assigned Managed Identity (UAMI) e un'identita Azure gestita, assegnata alla Function e utilizzabile senza password:

- **UAMI sorgente/storage** legge il primario e accede a pacchetto, CSV, sessioni, coda e log.
- **UAMI DR** crea dischi, NIC e VM nella destinazione. Deve essere autorizzata anche sui dischi primari per la copia diretta.

Un Private Endpoint collega un servizio a un indirizzo privato della Virtual Network (VNet), la rete Azure. Il Domain Name System (DNS) deve risolvere il nome del servizio in quell'indirizzo.

Terraform, lo strumento che configura le risorse Azure tramite file dichiarativi, crea ingresso privato della Function, integrazione VNet in uscita e Private Endpoint Blob/Queue/Table. La Function ha accesso pubblico disabilitato. Lo Storage Account preesistente deve avere accesso pubblico e shared key disabilitati; Terraform non ne modifica queste proprieta.

Starter, worker e API di stato usano HTTPS e UAMI. Il client storage del codice rifiuta nomi che non risolvono esclusivamente in indirizzi IPv4 privati: **non esiste fallback allo storage pubblico**. Il queue trigger e lo scale controller usano la connessione identity-based `DR_QUEUE_CONNECTION` e la rete privata configurata.

Le operazioni su VM/dischi/rete usano invece Azure Resource Manager (ARM), il servizio di gestione Azure, con contesti identita/subscription espliciti. Non trasferiscono file tramite connessioni remote alle VM e non richiedono peering tra primario e DR. Gli endpoint Microsoft di autenticazione e management restano necessari: non vanno confusi con gli endpoint dati privati dello storage.

## Quali risorse vengono create e quali devono gia esistere

| Quale risorsa deve esistere prima di Terraform | Quale risorsa crea Terraform |
|---|---|
| Resource Group di hosting, Storage Account StorageV2 e due UAMI nella subscription di hosting; possono essere in gruppi differenti. | Piano Flex Consumption, Function, VNet e subnet distinte per integrazione e Private Endpoint. |
| Postazione autorizzata con accesso alla rete privata. | Private Endpoint Function/Blob/Queue/Table e zone DNS private. |
| Nel DR: Resource Group, VNet/subnet, ASG, DES e, se necessari, Load Balancer/backend pool. | Container pacchetto/CSV/log/sessioni, coda di attivazione e coda dei messaggi falliti. |
| Ruoli delle identita e prerequisiti di cifratura. | Application Insights, Log Analytics workspace e diagnostica. |

Application Insights raccoglie telemetria del processo; Log Analytics permette di consultare log e metriche. I log per stage nel container Blob servono alla diagnosi, mentre lo stato della sessione e conservato separatamente.

I nomi predefiniti dei container sono `app-package`, `dr-configs`, `dr-logs`, `dr-sessions`. La coda e `dr-activation`; `dr-activation-poison` riceve i messaggi che esauriscono i tentativi di consegna. La mappa ambientale esistente `resource_names` permette nomi cliente, inclusi `session_container` e `activation_queue`. Non sono introdotte nuove variabili root o alias di letterali; gli input esistenti restano l'interfaccia per ambienti e tenant differenti.

## Come viene scelta la destinazione per ciascuna VM

Il Comma-Separated Values (CSV) e un file tabellare con colonne separate da virgole. Ogni riga contiene:

| Quale colonna compilare | Quale risorsa identifica |
|---|---|
| `Criticita` | Classe di Recovery Time Objective (RTO), obiettivo di tempo massimo di ripristino, usata per ordinare le attivazioni. Non costituisce una garanzia di tempo. |
| `Acronimo` | Identificativo dell'applicazione presente sulla VM, conservato nei risultati e nei log. Piu VM possono avere lo stesso acronimo. |
| `SourceSubscription` | Nome o identificatore della subscription primaria. |
| `SourceResourceGroup` | Resource Group della VM sorgente. |
| `SourceVmName` | Nome esatto della VM da replicare. |

Le cinque colonne devono comparire nell'ordine `Criticita,Acronimo,SourceSubscription,SourceResourceGroup,SourceVmName`, senza colonne GCP. Sono accettati header CSV standard e i nomi `'Criticita','Acronimo'` racchiusi negli apostrofi del riferimento. Valori vuoti, classi non riconosciute e vecchi CSV a tre colonne producono HTTP 400 prima dell'accodamento.

### Quale ordine di attivazione applica il worker

| Quale classe viene eseguita | Quali etichette cliente sono accettate |
|---|---|
| 1. `sistemico`. | `SISTEMICO (RTO 2 ore)`, `Sistemico (RTO 2 ore)`, `Sistemico (2h)`. |
| 2. `altamente-critico`. | `Altamente critico (RTO <= 48 ore)`, `Altamente critico (4h  adatto a RTO 4  8  24 o 48h)`. |
| 3. `critico`. | `Critico (RTO da 72 a 360 ore)`, `Critico (72h  adatto a RTO 72  120 o 360h)`. |
| 4. `non-critico`. | `Non critico (best effort  adatto a RTO oltre le 360h)`, `Non critico (RTO oltre le 360 ore)`. |

Maiuscole/minuscole e spazi ripetuti non modificano la classe. Il piano registrato contiene righe ordinate per priorita e, a parita di classe, per posizione originale nel CSV. Ogni tentativo termina prima di iniziare il successivo; un errore di replica non riordina o sopprime i tentativi indipendenti successivi. I prerequisiti di tutte le righe devono comunque passare prima della prima creazione.

L'ordine vale **all'interno della sessione**, non tra messaggi di sessioni diverse: Azure Queue Storage non viene usato come scheduler globale. Le classi non descrivono dipendenze applicative e non coordinano database o cluster. Il test [CSV disordinato](examples/vms-priorities.csv) mostra una VM per classe nell'ordine inverso.

Il worker risolve la primaria tramite UAMI sorgente e la relativa DR tramite UAMI DR: **nome primario + `target_subscription_suffix`**, predefinito `-DR`. La destinazione deve essere unica, abilitata, distinta dalla sorgente e nello stesso tenant Microsoft Entra, la directory delle identita. Non esiste una destinazione globale di fallback.

`target_name_suffix`, anch'esso predefinito `-DR`, determina invece i nomi dei prerequisiti: Resource Group, VNet, ASG, DES e Load Balancer. La subnet conserva il nome sorgente; VM e dischi conservano i propri nomi. I due suffissi sono indipendenti.

Esempio: la primaria `site-a` viene associata a `site-a-DR`; `rg-web` e `vnet-web` richiedono `rg-web-DR` e `vnet-web-DR`. Un'altra primaria `site-b` viene associata alla propria `site-b-DR`, anche nello stesso CSV.

Un Application Security Group (ASG) raggruppa NIC per l'applicazione delle regole di sicurezza. Un Disk Encryption Set (DES) indica la chiave utilizzata per cifrare i dischi. Il DES DR determina la regione della replica.

**La copia diretta richiede dischi nella stessa regione e subscription nello stesso tenant. Non realizza DR geografico.** Conserva la cifratura DR e rifiuta dischi esistenti originati da snapshot; non li cancella o sostituisce automaticamente.

## Come si svolge un'attivazione

1. **Il client genera un UUID nuovo.** Il client conserva `sessionId` prima di inviare la richiesta, quindi puo ritrovare la sessione anche se perde la risposta.
2. **Il client invia `sessionId` e `csvBlobPath` a Invoke.** La function key, un segreto condiviso valido fino alla rotazione, autorizza l'endpoint e viene trasportata nell'header `x-functions-key`.
3. **Invoke valida l'intera struttura del CSV.** Richiede tutte e cinque le colonne per ogni riga, una criticita riconosciuta e un acronimo valorizzato; rifiuta duplicati e percorsi non validi. Accetta 1-500 VM e un file fino a 1 MiB.
4. **Invoke registra il piano immutabile ordinato.** Blob Storage conserva `sessions/<sessionId>/request.json`: righe, posizione originale, priorita, impostazioni di replica, versione del blob e SHA-256, impronta crittografica del CSV. La registrazione e create-only, cioe non sovrascrive una richiesta esistente.
5. **Invoke registra lo stato iniziale e accoda il riferimento.** Il messaggio contiene soltanto versione del formato e `sessionId`, non un CSV che potrebbe essere modificato successivamente. Il client storage attende esplicitamente HTTP 201 dalla Queue prima di preparare HTTP 202.
6. **Il worker acquisisce lo stato con una scrittura condizionale.** Blob Storage confronta l'ETag, identificatore della versione del file: soltanto un concorrente puo acquisire quella versione della sessione. Il worker conserva l'identificativo del messaggio proprietario.
7. **Il worker esegue il preflight di tutte le righe.** Scopre sorgenti e destinazioni, valida la copia diretta e verifica esistenza/accessibilita dei prerequisiti. Se una riga fallisce, registra le non conformita rilevate e non crea workload per nessuna riga.
8. **Il worker esegue la replica delle VM in sequenza.** Per ogni VM ricontrolla i prerequisiti, copia/riusa i dischi, crea/riusa NIC e VM e collega il backend pool previsto.
9. **Il worker registra ogni esito.** Aggiorna `sessions/<sessionId>/state.json` e i log per stage, identificati dalla stessa sessione e dall'identita completa subscription/gruppo/VM.
10. **Il client legge Get-DRStatus con lo stesso `sessionId`.** L'API legge lo stato registrato, senza rileggere il CSV attuale e senza cercare il log modificato piu recentemente.

La risposta dello starter non attende preflight o replica. Il worker puo iniziare mentre il client sta ricevendo il 202. Il 202 non certifica prerequisiti, VM o salute applicativa.

## Quali controlli comprende il preflight

| Quale prerequisito controlla il worker | Quale attivita rimane esterna alla Function |
|---|---|
| Risoluzione univoca delle subscription e lettura della VM/dischi/NIC sorgenti. | Gestione delle subscription e scelta delle risorse autorizzate. |
| Resource Group DR necessari, VNet e subnet con il nome previsto. | Creazione rete, routing, DNS del workload e relative regole. |
| Tutti gli ASG derivati dalla NIC sorgente. Un ASG richiesto mancante blocca la sessione. | Riconciliazione delle regole di un Network Security Group (NSG), il filtro di traffico Azure, e delle configurazioni esterne. |
| Load Balancer e backend pool selezionabile, soltanto quando la sorgente li usa. | Confronto/riproduzione di frontend, regole e health probe, i controlli di raggiungibilita del servizio. |
| DES DR, tipo di cifratura supportato, stesso tenant e stessa regione per i dischi. | Preparazione di Key Vault/chiave, autorizzazione dell'identita DES e salute della chiave. |

Il preflight controlla presenza e lettura, **non certifica tutti i permessi di scrittura, la capacita compute o la coerenza delle configurazioni esterne**. Le autorizzazioni restano prerequisiti operativi. Una risorsa eliminata dopo il controllo puo comunque causare un fallimento durante la replica. Solo file di sessione e log vengono scritti durante il preflight; non vengono creati dischi, NIC o VM.

## Quale contratto espongono Invoke e Get-DRStatus

La richiesta Invoke contiene esattamente:

```json
{
  "sessionId": "b891dc62-d62f-4969-a427-4e24b35b857b",
  "csvBlobPath": "configurations/my-vms.csv"
}
```

La risposta accettata contiene `sessionId`, stato corrente, conteggi, orari e `statusUrl`. L'header `Location` indica la stessa URL relativa; `Retry-After: 5` suggerisce cinque secondi tra le consultazioni. I nomi precedenti dell'identificativo e gli override di parallelismo non sono accettati.

Get-DRStatus richiede `GET /api/Get-DRStatus?sessionId=<UUID>` oppure POST con `{"sessionId":"<UUID>"}`. Non richiede `csvBlobPath`. La risposta include gli esiti per VM e non usa successi di altre sessioni.

### Come il report conserva il formato abituale del cliente

Le nuove sessioni hanno `schemaVersion=2`. L'[esempio anonimo di stato](examples/status.json) mostra i quattro blocchi `sistemico`, `altamente-critico`, `critico`, `non-critico`, mantenendo nomi e tipi del riferimento.

| Quale parametro restituisce | Quale significato ha in Azure |
|---|---|
| `id`. | Alias del `sessionId` UUID generato dal client. Non viene generato un timestamp identificativo separato. |
| `activity`. | `dr-activation`: attivazione della bolla Azure. Il valore GCP `act-act` non viene copiato perche non si implementa un servizio applicativo active-active. |
| `running`. | Stringa `"true"` per una sessione non terminale, `"false"` per SUCCEEDED/FAILED. Non e una verifica di vitalita del processo. |
| `resource_completed` / `resource_completed_count`. | Elenco delle VM SUCCEEDED e relativo conteggio, mantenuto come stringa. |
| `resource_pending` / `resource_pending_count`. | VM in coda, in preflight, in lavorazione o non avviate; non vengono contate come completate. |
| `resource_error` / `resource_error_count`. | Mappa identificativo VM -> messaggio di errore, con conteggio stringa. |
| `resource_total`. | Numero totale delle VM di quella classe, come stringa; equivale alla somma completed + pending + error. |

Gli identificativi delle risorse nei blocchi sono `subscription-del-CSV/resource-group/nome-VM`, normalizzati in minuscolo. Questa chiave rimane stabile prima e dopo la risoluzione delle subscription e distingue VM omonime. Non e un resource ID ARM: gli identificativi subscription Azure risolti restano nei risultati dettagliati.

`results` conserva nome VM, subscription/gruppo, errore e stato Azure e aggiunge `criticita`, `acronimo`, `priorityClass`, `priority`, `csvRow`, `activationOrder`, `resourceKey`, `startedAt` e `completedAt`. Le date indicano il tentativo di gestione risorse, non la disponibilita dell'applicazione.

Lo stesso report per classi e contenuto nel JSON persistente `sessions/<sessionId>/state.json`, aggiornato con scritture condizionali. Non esiste un secondo file riepilogativo indipendente che potrebbe divergere dall'API. I log testuali degli stage Azure restano nel container log e riportano anche sessione, criticita e acronimo.

Le sessioni storiche con `schemaVersion=1` rimangono consultabili nel precedente formato Azure: il codice non inventa criticita o acronimi mancanti. Le nuove richieste richiedono sempre le cinque colonne.

| Quale risposta HTTP puo ricevere il client | Quale condizione indica |
|---|---|
| 202 da Invoke. | La richiesta e stata registrata e la Queue ha confermato l'accettazione, oppure la stessa sessione gia accettata e ancora in corso. |
| 200 da Invoke ripetuta. | La stessa richiesta appartiene a una sessione gia conclusa; viene restituito lo stato esistente senza nuova replica. |
| 200 da Get-DRStatus. | Lo stato richiesto e leggibile; puo anche contenere un fallimento. |
| 400. | Sessione/parametri/CSV non validi, righe incomplete o duplicate. |
| 401 o 403. | La piattaforma rifiuta autenticazione o accesso. Non aprire l'accesso pubblico per risolverlo. |
| 404. | CSV inesistente per Invoke oppure sessione inesistente per Get-DRStatus. |
| 409. | `sessionId` e gia associato a un percorso o contenuto CSV differente. |
| 413. | Il CSV supera 1 MiB. |
| 503. | Storage, identita o accettazione non confermabili. Il dettaglio tecnico resta nei log. |

| Quale stato persistente puo comparire | Che cosa significa per l'operatore |
|---|---|
| `PENDING`. | La richiesta esiste, ma non e stata ancora registrata una conferma della coda. Consultare lo stato e ritentare con lo stesso identificativo. |
| `QUEUED`. | La coda ha accettato la sessione; il worker non l'ha ancora acquisita. |
| `PREFLIGHT`. | Il worker sta verificando i prerequisiti; non ha avviato le creazioni workload. |
| `RUNNING`. | Il worker ha iniziato la fase di replica. |
| `SUCCEEDED`. | Il codice ha confermato la conclusione delle operazioni previste, non la salute dell'applicazione. |
| `FAILED`. | Preflight o replica falliti, oppure esecuzione interrotta rilevata alla riconsegna. Leggere esiti e `requiresReview`. |

### Come vengono gestiti ripetizioni e guasti

- Ritentare una POST incerta con **lo stesso `sessionId` e CSV invariato**. Il server non sovrascrive il manifest e non riaccoda una sessione gia confermata. Una risposta persa durante l'invio puo produrre piu messaggi, ma l'acquisizione condizionale impedisce di avviare due volte la stessa sessione.
- Il messaggio non scade automaticamente. Il runtime elimina quello elaborato con successo; dopo errori di esecuzione lo riconsegna fino a cinque tentativi, poi lo sposta nella coda `-poison`.
- Una sessione terminale non viene rieseguita dalle riconsegne. Se il medesimo messaggio ritorna dopo che il worker aveva acquisito la sessione senza concluderla, il codice registra `FAILED` con revisione richiesta: **non ripete automaticamente operazioni parziali**.
- Se lo storage non permette nemmeno di leggere/aggiornare lo stato, la consegna puo terminare nella poison queue. L'operatore deve controllare tale coda e la diagnostica; uno stato non terminale non prova che il processo sia ancora attivo.
- `batchSize=1`, `newBatchThreshold=0`, concorrenza dinamica disabilitata e un solo esecutore PowerShell per processo limitano la concorrenza locale. **Non sono un lock distribuito tra sessioni diverse**: non avviare sessioni sovrapposte sullo stesso workload.

## Quali autorizzazioni e prerequisiti verificare

Role-Based Access Control (RBAC) stabilisce quali operazioni un'identita puo eseguire. Lo scope e l'ambito della singola assegnazione.

| Quale identita utilizza il ruolo | Quale ruolo e quale ambito sono necessari |
|---|---|
| UAMI sorgente/storage. | Storage Blob Data Owner, Storage Queue Data Contributor e Storage Table Data Contributor sullo Storage Account esistente. Il ruolo Queue e ora obbligatorio per invio, ricezione, cancellazione e poison queue. |
| UAMI sorgente/storage. | Reader sui gruppi/subscription primari da leggere; Monitoring Metrics Publisher su Application Insights o relativo gruppo. |
| UAMI DR. | Disk Backup Reader sui dischi/gruppi primari: la copia richiede anche `Microsoft.Compute/disks/beginGetAccess/action`, non il solo Reader dell'altra identita. |
| UAMI DR. | Contributor sui gruppi workload DR; Network Contributor sulla rete quando separata; Reader sui gruppi di DES e Load Balancer se non gia incluso. La modifica della NIC avviene nel gruppo workload. |
| Identita del DES, distinta dalle UAMI. | Key Vault Crypto Service Encryption User sulla chiave/vault, oppure permessi equivalenti `get`, `wrapKey`, `unwrapKey`. |
| Operatore Terraform/deployment. | Contributor sul gruppo hosting, lettura e assegnazione delle UAMI, ruoli dati Blob/Queue necessari a creare container/code; ulteriori privilegi solo se deve assegnare ruoli. |

Il vault deve avere soft delete, purge protection, chiave attiva e accesso consentito al servizio di cifratura. Verificare anche Azure Policy, deny assignment e lock: un ruolo non supera questi divieti.

La postazione deve risolvere Function, relativo nome `scm` per la pubblicazione e storage in indirizzi privati. Deve inoltre raggiungere i servizi Microsoft di autenticazione/management e i repository delle dipendenze. L'autenticazione Azure non fornisce da sola connettivita privata.

## Come distribuire la soluzione

La configurazione usa solo il provider Terraform AzureRM. Gli input esistenti hanno tipi e descrizioni in [variables.tf](terraform/variables.tf); il cliente fornisce valori ambientali senza modificare blocchi risorsa.

### Quale script lanciare per la nuova versione

**Build e deploy possono essere eseguiti senza Terraform, sia in PowerShell sia in Bash.** Le build preparano un pacchetto locale; i deploy aggiornano una Function App esistente. Usare gli script del checkout aggiornato: il vecchio allegato PowerShell di 37 righe non contiene i nuovi parametri.

| Da quale ambiente si parte | Quale sequenza eseguire |
|---|---|
| Hosting gia configurato per `feature/async-session-id`, oppure per CSV/log. | Verificare branch/destinazione, poi build e deploy con i tre parametri del target oppure con gli output Terraform. Tra questi due rami i file Terraform non cambiano: criticita/acronimo/report sono modifiche del codice. |
| Vecchia consegna `delivery` senza coda applicativa e sessioni asincrone. | Prima esaminare/applicare il piano Terraform della nuova versione e predisporre i ruoli richiesti; poi build e deploy. Il solo deploy non crea coda, container sessioni o connessioni identity-based. |
| Prima installazione. | Predisporre i prerequisiti esterni, configurare gli input ambientali, verificare/applicare il piano; poi build e deploy. |
| Clone nuovo di un hosting esistente. | Usare il target esplicito senza recuperare lo stato Terraform. Se si sceglie invece la modalita Terraform, collegare il backend/stato corretto: il clone non contiene lo stato e `init` non lo ricostruisce. Non creare una seconda infrastruttura per far funzionare `output`. |

### Come pubblicare senza Terraform con i parametri del target

Sostituire i tre segnaposto con la subscription di hosting, il Resource Group e il nome della Function App esistente del cliente. Eseguire dalla radice del ramo aggiornato `feature/async-session-id-csv-log`.

**1. Preparare il pacchetto locale.** La build non usa subscription, Resource Group, Function App, login Azure o stato Terraform: il suo unico nuovo input e il percorso del ZIP. Questo permette di preparare un pacchetto prima di scegliere dove distribuirlo.

**2. Pubblicare sul target esplicito.** Il deploy richiede tutti e tre i riferimenti del target, legge da Azure l'hostname effettivo e usa tale indirizzo per le verifiche HTTP. Non occorre passare un URL, un tenant o una function key come ulteriori parametri. Il login Azure deve gia essere nel tenant corretto.

In PowerShell:

```powershell
$ErrorActionPreference = 'Stop'
./scripts/build.ps1 -PackagePath './out/function-app.zip'
./scripts/deploy.ps1 `
    -SubscriptionId '<ID-SUBSCRIPTION-HOSTING>' `
    -ResourceGroupName '<RESOURCE-GROUP-HOSTING>' `
    -FunctionAppName '<NOME-FUNCTION-APP>' `
    -PackagePath './out/function-app.zip'
```

In Bash, senza PowerShell:

```bash
set -euo pipefail
bash ./scripts/build.sh --package-path "./out/function-app.zip"
bash ./scripts/deploy.sh \
    --subscription-id "<ID-SUBSCRIPTION-HOSTING>" \
    --resource-group-name "<RESOURCE-GROUP-HOSTING>" \
    --function-app-name "<NOME-FUNCTION-APP>" \
    --package-path "./out/function-app.zip"
```

| Quale parametro usare in PowerShell | Quale parametro usare in Bash | A che cosa serve | Quando e obbligatorio o quale default applica |
|---|---|---|---|
| `-SubscriptionId` sul deploy. | `--subscription-id` sul deploy. | Identificare la subscription che contiene l'hosting, non la subscription workload DR. | Obbligatorio insieme agli altri due parametri del target nella modalita senza Terraform. |
| `-ResourceGroupName` sul deploy. | `--resource-group-name` sul deploy. | Identificare il Resource Group che contiene la Function App. | Obbligatorio nella modalita senza Terraform. |
| `-FunctionAppName` sul deploy. | `--function-app-name` sul deploy. | Identificare la Function App esistente da aggiornare; non e il nome di una singola funzione. | Obbligatorio nella modalita senza Terraform. |
| `-PackagePath` su build e deploy. | `--package-path` su build e deploy. | Build: percorso del ZIP da creare. Deploy: percorso del ZIP esistente da pubblicare. Usare lo stesso percorso nei due comandi. | Facoltativo: entrambi usano `out/function-app.zip` dello stesso repository dello script. |
| `-SkipModuleDownload` sulla build. | `--skip-module-download` sulla build. | Vietare nuovi download. PowerShell richiede i moduli in `function-app/Modules`; Bash richiede pacchetti e metadati in `out/module-cache`. | Facoltativo: senza lo switch la build scarica soltanto cio che manca, sempre nelle versioni fissate. Una cache assente/non valida causa errore, non un download nascosto. |
| `-TerraformDirectory` sul deploy. | `--terraform-directory` sul deploy. | Usare lo stato/output Terraform in alternativa ai tre riferimenti espliciti. | Facoltativo: senza i tre parametri del target il deploy mantiene la modalita precedente e usa `terraform/` del repository. Incompatibile con il target esplicito. |

Le modalita non si mescolano: input parziali o un target esplicito insieme alla directory Terraform vengono rifiutati prima delle modifiche Azure. In modalita esplicita **Terraform non deve essere installato e non vengono letti file di stato o output Terraform**. La build non dipende da Terraform in nessuna modalita.

Il target esplicito non crea hosting, identita, code, container o ruoli. Prima del deploy servono lo stesso hosting asincrono configurato, i permessi Azure e la connettivita privata descritti sopra. Assicurarsi che non siano in corso attivazioni: la pubblicazione puo riavviare il runtime.

I percorsi personalizzati relativi sono risolti rispetto alla directory da cui si lancia il comando. I default sono relativi al repository dello script; la build crea le directory di output mancanti. Il percorso della build deve terminare con `.zip` ed essere fuori da `function-app`, per non includere il pacchetto nel suo stesso sorgente. Se il pacchetto e gia stato approvato, si puo eseguire soltanto il deploy.

Per consultare i parametri PowerShell usare `Get-Help ./scripts/build.ps1 -Full` e `Get-Help ./scripts/deploy.ps1 -Full`. Gli script Bash espongono `--help` e `-h`, senza build o operazioni Azure.

### Come conservare la precedente modalita basata su Terraform

Per un checkout gia sul ramo corretto e con lo stato Terraform dell'ambiente, i comandi precedenti restano validi:

```powershell
$ErrorActionPreference = 'Stop'
if ((git branch --show-current) -ne 'feature/async-session-id-csv-log') {
    throw 'Selezionare prima il ramo CSV/log; lo script di deploy non cambia branch.'
}
git pull --ff-only origin feature/async-session-id-csv-log
if ($LASTEXITCODE -ne 0) { throw 'Aggiornamento del checkout non riuscito.' }
$Deployment = terraform -chdir=terraform output -json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Stato/output Terraform non disponibili.' }
$Deployment.function_app_name.value
$Deployment.resource_group_name.value
$Deployment.hosting_subscription_id.value
# Confermare questi tre riferimenti prima della pubblicazione.
./scripts/build.ps1
./scripts/deploy.ps1
```

Eseguire dalla radice del repository con PowerShell 7.6 e Azure CLI autenticata sulla postazione privata. Prima del riavvio assicurarsi che non vi siano attivazioni in corso. Lo script elimina l'eventuale impostazione legacy `AzureWebJobsStorage`: le impostazioni host identity-based devono essere gia presenti e corrette.

Se lo stato e fuori dal percorso standard, indicarlo esplicitamente:

```powershell
./scripts/deploy.ps1 -TerraformDirectory '/percorso/terraform-ambiente' -PackagePath './out/function-app.zip'
```

Non eseguire una copia isolata dell'allegato da una cartella arbitraria confidando nei default: questi sono calcolati rispetto alla posizione dello script nella cartella `scripts/`.

### Come eseguire build e deployment da Bash senza PowerShell

[scripts/build.sh](scripts/build.sh) e [scripts/deploy.sh](scripts/deploy.sh) sono la procedura Bash indipendente: **non richiamano `pwsh`, `powershell` o gli script `.ps1`**. PowerShell resta il runtime della Function in Azure, non un requisito della postazione che prepara/pubblica il pacchetto.

Usare Linux oppure Windows Subsystem for Linux (WSL), cioe un ambiente Linux su Windows. Oltre a Git e Azure CLI per il deploy, servono `curl`, `jq`, `zip`, `unzip`/`zipinfo`, `xmllint`, OpenSSL e le normali utility Linux. Terraform serve soltanto se si sceglie il deploy basato sui suoi output. Su Ubuntu, se queste utility mancano:

```bash
sudo apt-get update
sudo apt-get install -y curl jq zip unzip libxml2-utils openssl ca-certificates
```

Questo comando installa le utility, non Git, Terraform o Azure CLI. Azure CLI deve essere autenticata nel tenant cliente con i ruoli di deployment; Git deve essere autorizzato al repository privato. Rete privata, risoluzione dei nomi e assenza di attivazioni in corso restano prerequisiti del deploy. Lo stato Terraform serve soltanto nella modalita che lo utilizza.

**1. Controllare codice e destinazione prima di pubblicare.** Dalla radice del checkout:

```bash
set -euo pipefail
[[ "$(git branch --show-current)" == feature/async-session-id-csv-log ]] || {
    printf '%s\n' 'Selezionare prima il ramo feature/async-session-id-csv-log.' >&2
    exit 1
}
git pull --ff-only origin feature/async-session-id-csv-log
terraform -chdir=terraform output -json |
    jq '{subscription: .hosting_subscription_id.value,
         resourceGroup: .resource_group_name.value,
         functionApp: .function_app_name.value,
         api: .api_url.value}'
```

Il comando `terraform output` sopra e soltanto il controllo per la modalita precedente. Senza Terraform usare direttamente i tre riferimenti espliciti descritti nella [procedura parametrizzata](#come-pubblicare-senza-terraform-con-i-parametri-del-target); non eseguire quel comando.

**2. Generare il pacchetto e poi pubblicarlo.** Questi comandi senza target mantengono la modalita Terraform:

```bash
bash ./scripts/build.sh
bash ./scripts/deploy.sh
```

Il significato di ogni parametro e il confronto PowerShell/Bash sono nella [tabella della procedura parametrizzata](#come-pubblicare-senza-terraform-con-i-parametri-del-target). `--help` e `-h` mostrano sintassi, dipendenze e default senza eseguire operazioni.

Esempio con percorsi espliciti, inclusi spazi:

```bash
bash ./scripts/build.sh --skip-module-download
bash ./scripts/deploy.sh \
    --terraform-directory "/percorso/terraform cliente" \
    --package-path "./out/function-app.zip"
```

I percorsi personalizzati relativi sono risolti rispetto alla directory da cui si lancia il comando; i default sono risolti rispetto al repository dello script. Il vecchio uso posizionale `bash ./scripts/deploy.sh DIRECTORY ZIP` resta supportato, ma non va mescolato ai parametri nominati.

La build legge le versioni esatte da [requirements.psd1](function-app/requirements.psd1), senza eseguire il file come codice. Scarica pacchetti NuGet, cioe archivi ZIP dei moduli, verifica il checksum SHA-512 pubblicato dalla Gallery e controlla che ogni dipendenza sia coperta da una versione fissata compatibile. Non sceglie automaticamente versioni piu recenti. Crea una directory temporanea, esclude i vecchi moduli `Az.*`, inserisce soltanto quelli richiesti e controlla JSON, file obbligatori, permessi Linux e integrita dell'archivio. Esclude `local.settings.json` e i metadati NuGet, quindi sostituisce il pacchetto finale solo dopo il successo. Le cartelle dei moduli nel sorgente non vengono modificate.

La build Bash non esegue il parser PowerShell dei sorgenti: la verifica del codice applicativo resta nelle regressioni e nel collaudo del runtime. Questa differenza non introduce un interprete PowerShell nella procedura Bash.

Il deploy seleziona il target dai tre parametri oppure dagli output Terraform, rimuove l'eventuale vecchia impostazione `AzureWebJobsStorage` e pubblica il ZIP; le impostazioni host identity-based devono quindi essere gia corrette. Verifica tre funzioni e due HTTP 400 attesi senza `sessionId`, **senza avviare una replica**. La function key passa a `curl` tramite input standard, non nell'URL o negli argomenti del processo. Un errore interrompe lo script con exit code non zero, cioe un codice che segnala il fallimento al chiamante.

### Quale verifica reale ha superato la procedura Bash indipendente

Il 20 ottobre 2026 sono passati **40 casi locali**, anche in un container Ubuntu 24.04 dove PowerShell non era installato. Lo stesso container ha generato il pacchetto reale prima scaricando tutte le dipendenze, poi riutilizzando la cache senza nuovi download.

Fra le 20:14:22 e le 20:16:27 UTC, sulla postazione privata del lab, sono stati eseguiti i due comandi di build Bash e il deploy con i parametri nominati. Il `PATH`, cioe l'elenco delle directory in cui la shell cerca programmi, non conteneva `pwsh` o `powershell`. Ambiente: Bash 5.2.21, Azure CLI 2.91.0 e Linux.

Azure ha confermato il deployment; lo script ha trovato tre funzioni e ricevuto entrambi i 400 attesi. La lettura di una sessione esistente ha restituito schema 2, SUCCEEDED e un completamento per ciascuna delle quattro classi. Function, SCM, Blob e Queue risolvevano indirizzi privati; l'accesso pubblico della Function e rimasto disabilitato. Coda applicativa e poison queue erano vuote prima/dopo, nessuna nuova replica e stata avviata e le impostazioni dell'app del ramo padre erano invariate. La postazione e stata nuovamente deallocata.

Sono passate anche le otto suite applicative PowerShell e i 14 test Terraform del runner completo. Queste regressioni di sviluppo non sono una dipendenza degli script Bash. La prova non certifica un tenant cliente diverso, macOS o una shell Windows non Linux.

### Quale verifica reale ha superato lo script PowerShell

Il 20 ottobre 2026 sono stati eseguiti realmente **`./scripts/build.ps1` e `./scripts/deploy.ps1`**, non soltanto l'equivalente Bash, su una Function CSV/log privata separata. Ambiente: PowerShell 7.6.1 su Linux e Azure CLI 2.91.0.

Nella consegna precedente il file PowerShell di 37 righe fornito come allegato coincideva byte per byte con quello del repository. **La versione corrente lo estende con i parametri del target: l'allegato storico non e piu la copia aggiornata.** Il deployment storico Azure e riuscito; lo script ha verificato tutte e tre le funzioni e le due risposte HTTP 400 senza `sessionId`. Dopo la pubblicazione e stata riletta una sessione esistente schema 2 con le quattro classi del report. Le code erano vuote prima e dopo; nessuna nuova replica DR e stata avviata. E stato verificato anche che un pacchetto assente blocca lo script prima delle chiamate Azure.

Questo prova la pubblicazione su hosting gia compatibile, non crea o valida automaticamente i prerequisiti di un'altra infrastruttura cliente. La postazione usata nel test e stata riportata deallocata e l'app del ramo padre non e stata ridistribuita. Il collaudo non e un'esecuzione su Windows o sul tenant del cliente.

### Quale collaudo reale ha superato la modalita senza Terraform

Il 21 ottobre 2026, dalle **00:30:55 alle 00:34:22 ora italiana** (20 ottobre 22:30:55-22:34:22 UTC), sono state eseguite **due build reali e due pubblicazioni Azure reali** sulla Function CSV/log privata separata:

1. PowerShell 7.6.1 ha creato un ZIP in un percorso con spazi e lo ha pubblicato passando subscription, Resource Group, nome Function App e percorso del pacchetto.
2. Bash 5.2.21 ha creato un secondo ZIP in un altro percorso con spazi e lo ha pubblicato con gli stessi tre riferimenti del target e il proprio pacchetto.

Terraform non era disponibile nel `PATH` di nessuna delle due prove; Bash non poteva richiamare PowerShell. Entrambi i deploy hanno ottenuto conferma di successo da Azure, verificato tre funzioni e ricevuto i due HTTP 400 attesi. Dopo ciascuna pubblicazione e stato riletto il report persistente schema 2, SUCCEEDED, con un completamento per ognuna delle quattro classi. Le code erano vuote prima, fra i deploy e dopo; nessuna nuova replica DR e stata avviata. Sono rimasti invariati le impostazioni della Function del ramo padre, gli indirizzi privati e il blocco dell'accesso pubblico. La postazione e stata deallocata al termine.

I test locali aggiornati comprendono **37 casi PowerShell e 68 casi Bash**: pacchetti personalizzati, target incompleti/misti, discovery dell'hostname, errori Azure/HTTP e compatibilita della modalita Terraform. Un container Ubuntu 24.04 senza Terraform e senza PowerShell installati ha eseguito i 68 casi Bash e due build reali, una con download e una da cache. Il runner completo ha superato le nove suite PowerShell e i 14 test Terraform preesistenti.

Le due pubblicazioni verificano questa procedura su hosting compatibile, non il provisioning di un nuovo ambiente, una nuova attivazione DR, Windows o il tenant del cliente.

### Come preparare una prima installazione autorizzata

Il repository e privato: il cliente deve essere autorizzato e autenticato in GitHub prima del clone/pull. Il login Azure non sostituisce quello GitHub. Usare il meccanismo aziendale approvato, senza inserire token negli URL.

```powershell
git clone --branch feature/async-session-id-csv-log --single-branch https://github.com/lupass93/attivazione-dr-bolla.git
Set-Location attivazione-dr-bolla
Copy-Item ./terraform/terraform.tfvars.example ./terraform/terraform.tfvars
az login
```

Compilare il file locale con subscription di hosting, gruppo, storage, identita, nome Function, regione e prefissi di rete non sovrapposti. Se storage o identita sono in altri gruppi, usare gli input `*_resource_group_name` corrispondenti. Non pubblicare valori reali, stato o piani Terraform.

```powershell
terraform -chdir=terraform init
terraform -chdir=terraform validate
terraform -chdir=terraform plan -out=deployment.tfplan
terraform -chdir=terraform apply deployment.tfplan
./scripts/build.ps1
./scripts/deploy.ps1
```

Esaminare il piano prima dell'apply: non deve gestire o sostituire i prerequisiti esistenti. La preparazione scarica le versioni fissate in [requirements.psd1](function-app/requirements.psd1), controlla la sintassi e crea il pacchetto senza `local.settings.json`. La pubblicazione verifica l'indicizzazione di tutte e tre le funzioni e HTTP 400 senza `sessionId`, senza avviare replica.

Per l'alternativa interamente Bash usare la [procedura indipendente da PowerShell](#come-eseguire-build-e-deployment-da-bash-senza-powershell). La stessa distinzione fra aggiornamento applicativo e prima installazione vale per entrambi i linguaggi.

## Come il client avvia e segue una sessione

Preparare un CSV reale usando [l'esempio semplice](examples/vms.csv) o [l'esempio multisubscription](examples/vms-multisubscription.csv). Gli esempi contengono soltanto nomi fittizi.

```powershell
$Outputs = terraform -chdir=terraform output -json | ConvertFrom-Json
$Subscription = $Outputs.hosting_subscription_id.value
$ResourceGroup = $Outputs.resource_group_name.value
$FunctionName = $Outputs.function_app_name.value
$ApiUrl = $Outputs.api_url.value
$StorageAccount = $Outputs.storage_account_name.value
$CsvContainer = $Outputs.csv_container_name.value
$CsvBlobPath = 'configurations/my-vms.csv'
az storage blob upload --account-name $StorageAccount --container-name $CsvContainer `
    --name $CsvBlobPath --file ./my-vms.csv --auth-mode login --overwrite --content-type text/csv
if ($LASTEXITCODE -ne 0) { throw 'CSV upload failed.' }

$SessionId = [guid]::NewGuid().ToString('D')
# Conservare SessionId nel sistema chiamante prima della POST.
$FunctionKey = az functionapp keys list --subscription $Subscription --resource-group $ResourceGroup `
    --name $FunctionName --query functionKeys.default -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Function key unavailable.' }
$Headers = @{ 'x-functions-key' = $FunctionKey }
$Body = @{ sessionId = $SessionId; csvBlobPath = $CsvBlobPath } | ConvertTo-Json
$Accepted = Invoke-RestMethod -Method Post -Uri "$ApiUrl/Invoke-DRReplication" `
    -Headers $Headers -ContentType 'application/json' -Body $Body -TimeoutSec 120
$Accepted | Format-List sessionId, status, queueConfirmed, statusUrl

do {
    Start-Sleep -Seconds 5
    $Status = Invoke-RestMethod -Method Get -Uri "$ApiUrl/Get-DRStatus?sessionId=$SessionId" `
        -Headers $Headers -TimeoutSec 60
    $Status | Select-Object sessionId, status, phase
} while ($Status.status -notin @('SUCCEEDED', 'FAILED'))
$Status.results | Format-Table sourceSubscriptionId, sourceResourceGroup, vmName, status, error
Remove-Variable FunctionKey, Headers
```

Il client puo consultare la sessione subito usando l'identificativo che gia conosce. Se la POST perde la risposta, non creare un nuovo identificativo per il retry. Verificare infine risorse Azure e servizio applicativo: gli esiti del codice non sostituiscono questi controlli.

## Quali verifiche automatiche sono disponibili

Eseguire dalla radice:

```powershell
./scripts/test.ps1
```

Il comando esegue le regressioni multisubscription e copia diretta, i nuovi test di accettazione/worker/stato/preflight e i test Terraform con provider simulato. Le chiamate Azure sono simulate nei test locali; i test reali richiedono un ambiente dedicato con accesso privato.

Il runner include anche [tests/bash-deployment.sh](tests/bash-deployment.sh); richiede quindi Bash e le utility della build elencate sopra. Il test crea un `PATH` senza PowerShell e verifica download/cache, checksum, dipendenze, formato del pacchetto, parametri, percorsi con spazi e interruzione sugli errori Azure/HTTP. Per eseguire soltanto questi test, senza interprete PowerShell e senza chiamate Azure reali:

```bash
bash ./tests/bash-deployment.sh
```

Il runner include [tests/powershell-deployment.ps1](tests/powershell-deployment.ps1): verifica build, pacchetti personalizzati, modalita Terraform precedente e target espliciti con Terraform assente. I controlli locali del deploy simulano Azure e non pubblicano codice. I due script di test possono essere eseguiti singolarmente senza Terraform; il runner completo richiede Terraform soltanto per i test infrastrutturali finali.

I tre script live sono separati dai test locali per non avviare accidentalmente risorse: [validazione delle richieste](tests/live-request-validation.ps1), [preflight negativo](tests/live-preflight.ps1) e [attivazione e verifica Azure](tests/live-session.ps1). Leggono gli output Terraform locali, richiedono login e ruoli di verifica sulle risorse del lab e conservano prove in `out/live`, esclusa da Git. Gli ultimi due richiedono `-CsvBlobPath`, `-TargetSubscriptionId` e `-TargetResourceGroup`. Preparare soltanto risorse di test autorizzate; il test negativo richiede un ASG DR deliberatamente assente, mentre quello positivo richiede una destinazione workload inizialmente vuota e una NIC sorgente con ASG/backend pool. Non eseguirli su un ambiente cliente senza approvazione.

Il nuovo [collaudo live delle quattro priorita](tests/live-csv-priority.ps1) usa gli stessi tre parametri e richiede quattro VM sorgenti, una per classe, elencate nel CSV in ordine inverso. Verifica il piano ordinato, gli istanti di inizio/fine dei tentativi, il formato JSON durante l'avanzamento, i log per stage e l'ordine effettivo di creazione delle VM in Azure. Le destinazioni devono essere inizialmente vuote; il test crea workload reali.

| Quale requisito viene verificato | Quale prova ne dimostra il comportamento |
|---|---|
| REQ-ASYNC-001: conservare multisubscription e copia diretta. | Regressioni di routing/contesti e 16 scenari di copia senza comandi snapshot. |
| REQ-ASYNC-002: identificativo generato dal client e sessione persistente. | UUID richiesto, manifest immutabile, conflitto 409 e retry con lo stesso ID. |
| REQ-ASYNC-003: rispondere dopo conferma della coda, senza eseguire la replica nello starter. | Mancata conferma produce 503; starter senza chiamate al core e con messaggio registrato prima del 202. |
| REQ-ASYNC-004: controllare soltanto i prerequisiti necessari, prima delle creazioni. | ASG/VNet/subnet/LB/pool/gruppi mancanti bloccano; configurazioni esterne non riconciliate; una riga fallita impedisce tutte le creazioni. |
| REQ-ASYNC-005: leggere lo stato della sessione richiesta. | Nessun recupero di successi precedenti, omonimi distinti e CSV modificato senza effetti retroattivi. |
| REQ-CSVLOG-001: usare le due colonne cliente prima delle tre Azure. | Nove etichette accettate, metadati obbligatori, layout e duplicati validati prima dell'accodamento. |
| REQ-CSVLOG-002: rispettare le quattro priorita. | Ordine reale delle chiamate al core, stabilita delle parita, errori e piano immutabile. |
| REQ-CSVLOG-003: allineare JSON e log senza perdere il contesto Azure. | Nomi/tipi dei blocchi cliente, contatori coerenti, VM omonime, acronimo nei risultati e nei log, stato persistente uguale alla proiezione pubblica. |
| CON-ASYNC-001: vietare fallback dati pubblico. | Terraform configura Private Endpoint/identita; il codice rifiuta risoluzioni non private e connessioni non HTTPS. Il collaudo Azure deve verificarne il percorso effettivo. |
| CON-BASH-001: non richiedere o eseguire PowerShell dalla procedura Bash. | Test con `PATH` privo di interpreti PowerShell, build reale in Ubuntu senza PowerShell installato e deployment nativo dal lab privato. |
| REQ-BASH-001: generare il pacchetto con versioni fissate e controlli espliciti. | Download Gallery, SHA-512, dipendenze NuGet, build da cache, errori, JSON e contenuto ZIP coperti da test. |
| REQ-BASH-002: pubblicare e verificare il codice senza avviare DR. | Tre funzioni, due 400 previsti, report schema 2 esistente, code vuote e impostazioni del ramo padre invariate nel collaudo Azure. |
| REQ-BUILD-001: preparare un ZIP locale con percorso esplicito, senza target Azure o Terraform. | Build PowerShell e Bash con percorsi relativi/con spazi, default conservati e output nel sorgente rifiutato. |
| REQ-DEPLOY-001: pubblicare con i tre riferimenti del target, senza Terraform. | Test PowerShell/Bash con Terraform assente, hostname restituito da Azure e input parziali/misti bloccati prima delle modifiche; compatibilita degli output Terraform verificata separatamente. |

### Quale collaudo del nuovo CSV e report e stato completato

Il 20 ottobre 2026 la nuova feature e stata distribuita su una Function privata separata, senza ridistribuire l'app del ramo padre. Un CSV con quattro VM e ordine intenzionalmente inverso ha prodotto questo ordine reale di creazione:

| Quale classe e stata attivata | In quale riga del CSV si trovava | Quando Azure ha creato la VM, in UTC |
|---|---|---|
| Sistemico. | Riga dati 4. | 17:38:34. |
| Altamente critico. | Riga dati 3. | 17:39:07. |
| Critico. | Riga dati 2. | 17:39:28. |
| Non critico. | Riga dati 1. | 17:39:50. |

I timestamp dei tentativi confermano anche che la VM successiva non e stata avviata prima della conclusione del tentativo precedente. Le quattro VM e i guest agent erano operativi; quattro dischi OS copiati direttamente, quattro NIC con IP statico/ASG/backend pool e zero snapshot sono stati verificati su Azure.

- **Regressioni locali:** tutte superate, inclusi 28 controlli CSV/ordine, 33 controlli JSON/metadati e 14 scenari Terraform preesistenti.
- **Richieste reali:** 12 controlli superati, compresi RTO sconosciuto, acronimo mancante e CSV precedente a tre colonne.
- **Avanzamento reale:** 688 asserzioni superate su 22 osservazioni, log e risorse; i contatori persistenti e restituiti dall'API erano uguali e i quattro log di completamento contenevano sessione, criticita e acronimo.
- **Confronto con il riferimento:** tutti i 35 controlli sui nomi/tipi dei campi cliente sono passati anche sul JSON prodotto in Azure.
- **Misure di questa prova:** accettazione HTTP 202 in 3,01 secondi; worker 133,65 secondi; conclusione 142,80 secondi dopo la conferma della coda. Non sono garanzie RTO o di prestazione.
- **Code finali:** attivazione e poison queue vuote. Ramo padre e configurazione della sua Function invariati; nessun file di riferimento reale del cliente e stato pubblicato.

Il test esercita quattro classi nella stessa sessione e una coppia primaria/DR reale. Le parita di classe, i fallimenti e gli omonimi multisubscription sono verificati nei test locali; non si dichiara un test Azure su due coppie distinte o della salute applicativa.

### Quale collaudo storico del ramo padre era stato completato il 20 ottobre 2026

Il test seguente riguarda il ramo padre `feature/async-session-id`, non certifica le nuove colonne o il report per criticita. Ha usato una Function separata dalla consegna precedente, nello stesso tenant del laboratorio, con una coppia primaria/DR reale. L'infrastruttura ha creato 29 risorse aggiuntive senza aggiornare o distruggere risorse gestite preesistenti nel piano Terraform. Le connessioni Function/Blob/Queue/Table sono private; l'accesso pubblico di Function e storage e disabilitato.

| Quale flusso e stato verificato | Quale esito e stato osservato |
|---|---|
| Richieste senza credenziali, identificativo mancante/non valido, JSON non valido, CSV assente/incompleto/duplicato. | PASS: nove controlli reali; nessuna sessione accettata per input rifiutati. |
| ASG DR deliberatamente mancante. | PASS: 19 controlli; sessione `FAILED` nella fase di preflight, indicazione dell'ASG e nessuna creazione workload. |
| Nuova attivazione da destinazione workload vuota. | PASS: 15 controlli; una VM e guest agent operativi, due dischi copiati direttamente e cifrati con DES DR, una NIC con IP statico, ASG e backend pool; zero snapshot. |
| Ripetizione della richiesta con lo stesso identificativo. | PASS durante l'attivazione e dopo la conclusione; stesso stato/sessione, senza creare un secondo workload. |
| Durata della richiesta e del lavoro. | HTTP 202 in 4,45 secondi; worker attivo per 52,33 secondi; conclusione 61,23 secondi dopo la conferma della coda. Sono misure di questa prova, non limiti o garanzie di servizio. |
| Code al termine della verifica. | Nessun messaggio rimasto nella coda di attivazione o nella poison queue dopo archiviazione e rimozione del solo messaggio del test negativo. |

Il collaudo ha individuato e corretto due differenze rispetto ai mock: il binding PowerShell puo consegnare una hashtable gia deserializzata e la creazione condizionale Blob puo restituire `409 BlobAlreadyExists`. Entrambi i casi sono coperti da regressioni; conflitti diversi non vengono interpretati come successo.

Durante le prime prove negative il frontend privato ha restituito anche HTTP 503 non applicativi. I test registrano i retry limitati della richiesta identica e non mascherano errori JSON della Function. La prova positiva finale non ha richiesto tali retry. Non e stata certificata una disponibilita o una latenza garantita.

Il collaudo storico del 12 ottobre riguardava il vecchio percorso con snapshot: non e usato come prova di questa architettura. Due coppie reali nello stesso CSV restano non verificate, perche il tenant disponibile non contiene quattro subscription utilizzabili; routing e VM omonime su due coppie sono verificati nei test simulati. Salute applicativa, consistenza multi-disco e resistenza a tutti i guasti non sono certificate.

## Quali limiti restano intenzionalmente fuori da questa modifica

- Il riuso dei dischi non ne aggiorna il contenuto. Una nuova sessione non garantisce un nuovo punto di ripristino.
- Il riuso VM confronta dimensione e disco OS, non riconcilia dischi dati, avvio, identita, estensioni o salute. Non esiste rollback automatico.
- Il codice ricrea una NIC e una configurazione IP primaria, conserva l'IP come statico e aggiunge il backend pool previsto. Non riproduce tutta la topologia o tutte le proprieta di sicurezza e non rimuove collegamenti esterni.
- Le copie per disco non coordinano le scritture applicative. Consistenza, Recovery Point Objective (RPO), perdita dati massima ammessa, e Recovery Time Objective (RTO), tempo massimo di ripristino, richiedono prove applicative.
- Non esistono lock tra sessioni diverse, smantellamento automatico, autorizzazione del chiamante per singolo workload o retention automatica dei log/sessioni.
- `functionTimeout=-1` rimuove il limite configurato di esecuzione, non riavvii o eventi di piattaforma. La coda elimina la dipendenza della replica dalla risposta HTTP, non rende il worker ininterrompibile.
- La migrazione cambia il contratto delle API: le vecchie chiamate senza `sessionId` non sono compatibili. I vecchi log non vengono trasformati in nuove sessioni.

## Cosa ho dato per scontato

La documentazione presuppone prerequisiti e autorizzazioni predisposti dall'organizzazione. Il preflight verifica soltanto le condizioni descritte, non una conformita generale dell'ambiente. Le due coppie DR reali richiedono quattro subscription; non si simula una seconda coppia facendo convergere primarie differenti nella stessa destinazione.

## Le 3 domande che ti verrebbe da farmi

1. **Il 202 significa che il DR e pronto?** No: significa accettazione confermata. Consultare quella sessione e verificare l'applicazione.
2. **Posso cambiare il CSV mentre il worker lavora?** La sessione usa le righe gia registrate; una nuova richiesta con lo stesso ID e contenuto diverso viene rifiutata.
3. **Una coda garantisce una sola esecuzione?** No: la consegna puo ripetersi. Il codice riconosce duplicati della stessa sessione; le sessioni diverse sullo stesso workload richiedono coordinamento esterno.

## Fonti

- Implementazione: [starter](function-app/Invoke-DRReplication/run.ps1), [worker](function-app/Process-DRSession/run.ps1), [stato](function-app/Get-DRStatus/run.ps1), [sessioni/storage](function-app/Modules/DRSessions/DRSessions.psm1), [replica e prerequisiti](function-app/Modules/DRCore/DRCore.psm1), [infrastruttura](terraform/main.tf).
- Passaggi 1-5: [pattern Microsoft di richiesta/risposta asincrona](https://learn.microsoft.com/azure/architecture/patterns/asynchronous-request-reply), [conferma Queue Put Message](https://learn.microsoft.com/rest/api/storageservices/put-message).
- Passaggio 6: [scritture Blob condizionali e concorrenza](https://learn.microsoft.com/azure/storage/blobs/concurrency-manage).
- Passaggi 7-8: [copia diretta dei dischi tra subscription](https://learn.microsoft.com/azure/virtual-machines/scripts/copy-managed-disks-to-same-or-different-subscription); l'elenco dei prerequisiti applicativi e definito nel codice del progetto.
- Passaggi 9-10: [Queue trigger, identita, riconsegne e poison queue](https://learn.microsoft.com/azure/azure-functions/functions-bindings-storage-queue-trigger), [configurazione di concorrenza e encoding](https://learn.microsoft.com/azure/azure-functions/functions-bindings-storage-queue#host-json).
- Rete: [Private Endpoint e integrazione VNet di Azure Functions](https://learn.microsoft.com/azure/azure-functions/functions-networking-options), [identita gestite](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview).
- Runtime e limiti: [PowerShell 7.6](https://learn.microsoft.com/azure/azure-functions/functions-reference-powershell#powershell-versions), [timeout di esecuzione e HTTP](https://learn.microsoft.com/azure/azure-functions/functions-scale#function-app-timeout-duration).
- Ordinamento: [Sort-Object con ordine stabile](https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/sort-object?view=powershell-7.6) e [assenza di garanzia FIFO in Storage Queue](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-azure-and-service-bus-queues-compared-contrasted#foundational-capabilities). La coda trasporta una sessione, non decide la priorita delle sue VM.
- Permessi: [ruoli dati Storage](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/storage), [ruoli Compute](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/compute).
- Build Bash, passo 1: [download manuale dei pacchetti Gallery e dipendenze escluse dal singolo nupkg](https://learn.microsoft.com/powershell/gallery/how-to/working-with-packages/manual-download?view=powershellget-3.x), [intervalli di versione NuGet](https://learn.microsoft.com/nuget/concepts/package-versioning#version-ranges), [implementazione e controlli](scripts/build.sh).
- Deploy Bash, passo 2: [package deployment Flex Consumption e endpoint privato](https://learn.microsoft.com/azure/azure-functions/deployment-zip-push?pivots=flex-consumption-plan), [implementazione](scripts/deploy.sh), [test ripetibili](tests/bash-deployment.sh).
- Target esplicito: [lettura della Function App con Azure CLI](https://learn.microsoft.com/cli/azure/functionapp#az-functionapp-show), [parametri subscription/gruppo/nome/pacchetto del deployment](https://learn.microsoft.com/cli/azure/functionapp/deployment/source#az-functionapp-deployment-source-config-zip), [parameter set PowerShell mutuamente esclusivi](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_parameter_sets?view=powershell-7.6).

## Glossario della procedura Bash

- **NuGet package:** archivio ZIP del modulo pubblicato nella Gallery; non comprende automaticamente i moduli da cui dipende.
- **Cache:** copie locali dei pacchetti e dei metadati usate fra build; ogni build verifica nuovamente i checksum.
- **SHA-512:** Secure Hash Algorithm a 512 bit, usato per confrontare l'impronta del pacchetto con quella pubblicata dalla Gallery.
- **xmllint:** utility che legge i metadati XML della Gallery e dei pacchetti, senza eseguire il codice PowerShell.
- **SCM:** endpoint di deployment della Function, distinto dall'endpoint delle API; richiede connettivita e risoluzione dei nomi private quando l'hosting e privato.

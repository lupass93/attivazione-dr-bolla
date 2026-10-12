# Attivazione Bolla - DR Replication Function

Azure Functions privata, PowerShell 7.6 e piano Flex Consumption: legge da Azure Storage un file Comma-Separated Values (CSV), elenco tabellare delle VM sorgenti, e ricrea Virtual Machine (VM) nel Disaster Recovery (DR), cioe l'ambiente di ripristino. Terraform usa solo AzureRM; due User-Assigned Managed Identity (UAMI), identita Azure senza password, separano letture/storage e operazioni DR.

> Questa soluzione deriva dalla copia corretta di [stefze/Attivazione-Bolla](https://github.com/stefze/Attivazione-Bolla). Il README descrive il codice attuale; le migliorie indicate come proposte non sono implementate.

## Indice

- [Architettura e risorse](#architettura-e-risorse)
- [Assunzioni e prerequisiti nel DR](#assunzioni-e-prerequisiti-nel-dr)
- [Esempi delle subscription sorgenti e DR](#esempi-delle-subscription-sorgenti-e-dr)
- [Esempi dei nomi delle risorse DR](#esempi-dei-nomi-delle-risorse-dr)
- [Esempi dei nomi dell'hosting Terraform](#esempi-dei-nomi-dellhosting-terraform)
- [Responsabilita della Function sulle risorse DR](#responsabilita-della-function-sulle-risorse-dr)
- [Come opera Invoke-DRReplication](#come-opera-invoke-drreplication)
- [Come opera Get-DRStatus](#come-opera-get-drstatus)
- [Pre-check prima del deployment](#pre-check-prima-del-deployment)
- [Autenticazione e permessi](#autenticazione-e-permessi)
- [Struttura del progetto](#struttura-del-progetto)
- [Deployment della soluzione](#deployment-della-soluzione)
- [Configurazione del CSV](#configurazione-del-csv)
- [Attivazione e verifica](#attivazione-e-verifica)
- [Limiti e troubleshooting](#limiti-e-troubleshooting)
- [Migliorie prioritarie e verifiche](#migliorie-prioritarie-e-verifiche)
- [Riferimenti](#riferimenti)

## Architettura e risorse

`Invoke-DRReplication` legge il CSV, individua VM/rete/dischi sorgenti, crea snapshot e dischi cifrati, ricrea NIC e VM e collega i backend pool. Una Network Interface (NIC) e l'interfaccia di rete della VM. `Get-DRStatus` legge CSV e log senza creare risorse.

Le due Application Programming Interface (API), interfacce di chiamata HTTP, usano Azure Resource Manager (ARM), il management endpoint Azure, per leggere e creare risorse. La replica non trasferisce file via sessioni remote nelle VM e non richiede peering al primario per queste operazioni di management. Il percorso privato verso Function e storage resta invece necessario ai client.

| Quali risorse devono gia esistere | Quali risorse crea Terraform |
|---|---|
| Resource Group di hosting, Storage Account StorageV2 e due UAMI. | Piano Flex Consumption, Function privata, rete di hosting e due subnet separate. |
| Nel DR: Resource Group, VNet/subnet, ASG, Load Balancer/backend pool e DES con Key Vault/chiave. | Private Endpoint della Function e dei servizi Blob/Queue/Table, con zone DNS private. |
| Postazione con percorso di rete verso i servizi privati. | Container deployment/CSV/log, default `app-package`, `dr-configs`, `dr-logs`, Application Insights, Log Analytics workspace e diagnostica. |

Virtual Network (VNet) e la rete privata; Application Security Group (ASG) raggruppa interfacce nelle regole di sicurezza. Disk Encryption Set (DES) collega i dischi alla chiave di cifratura. Un Private Endpoint rende raggiungibile un servizio tramite IP privato; il Domain Name System (DNS) deve risolvere il nome del servizio in quell'IP.

Terraform non crea o assegna i ruoli delle identita e non gestisce Resource Group, Storage Account o UAMI preesistenti. Nella configurazione attuale questi quattro prerequisiti devono appartenere alla subscription di hosting; possono essere in Resource Group differenti. La rete di hosting della Function e distinta dalla rete delle VM DR.

**Tre percorsi di osservabilita distinti:** i log di avanzamento vengono scritti da UAMI1 nel container log configurato, default `dr-logs`, e letti dall'API di stato; log/telemetria dell'host vengono inviati ad Application Insights con la stessa UAMI1 e autenticazione Microsoft Entra; le diagnostic settings inoltrano log/metriche dei servizi al workspace. Configurare questi percorsi non equivale a verificare salute o esito delle VM.

**Destinazione attuale:** il CSV puo contenere piu subscription primarie, ma tutte le righe usano la stessa DR, impostata con `dr_subscription_id` / `TARGET_SUBSCRIPTION_ID`. Il suffisso `TARGET_SUBSCRIPTION_SUFFIX` non viene usato per risolvere una DR diversa per ciascuna primaria. Il requisito primaria A -> A-DR, primaria B -> B-DR richiede una correzione del codice, non la sola rimozione dell'app setting.

## Assunzioni e prerequisiti nel DR

La Function ricostruisce il workload dentro un ambiente gia predisposto; non replica la configurazione completa del sito primario. Il gestore del DR deve verificare questi prerequisiti per ogni VM del CSV prima della POST.

| Quale prerequisito predisporre | Quale coerenza verificare con il primario |
|---|---|
| Resource Group delle VM replicate, della rete e della cifratura. | Nomi derivabili dalle risorse sorgenti con i suffissi configurati, default `-DR`; permessi dell'identita DR sugli ambiti effettivi. |
| VNet e subnet DR. | VNet/Resource Group con i suffissi attesi; subnet con lo stesso nome sorgente. Il prefisso deve contenere l'IP sorgente, libero in DR: la nuova NIC lo riutilizza come statico. |
| ASG DR, se presenti sulla NIC sorgente. | Nomi sorgenti con suffisso, nel Resource Group della VNet DR. Il codice non li crea; se un ASG manca, prosegue senza quel collegamento e scrive un warning. |
| Load Balancer e backend pool DR, se il primario usa un Load Balancer. | Load Balancer/Resource Group con suffisso e pool selezionabile dal codice. Regole, probe, frontend e criteri di traffico devono essere gia configurati e verificati. |
| DES e Key Vault/chiave DR. | Il disco OS sorgente deve avere un DES. Nome e Resource Group di quel DES, con suffisso, individuano il DES DR; la sua regione determina quella delle nuove risorse workload. Verificare chiave valida, identita DES autorizzata e accesso al vault. |
| Policy di rete e capacita DR. | Network Security Group (NSG), cioe regole di traffico, routing, DNS e uscita coerenti con l'isolamento richiesto; disponibilita del modello VM, quota e compatibilita dei dischi. Non vengono ricopiati automaticamente. |
| Compatibilita di copia e regione. | Il codice usa `Copy` direttamente dal disco, non una pipeline di trasferimento cross-region. Verificare il supporto dell'operazione per dischi, cifratura e regioni effettive; il solo cambio di `location` non certifica DR geografico. |

Coerenza non significa copia integrale: il codice preserva solo le proprieta esplicitamente gestite. La presenza delle risorse non certifica permessi, isolamento di rete, disponibilita applicativa o consistenza dei dati.

**Convenzione dei nomi:** Resource Group delle VM replicate, VNet, Load Balancer e DES = nome sorgente + rispettivo suffisso, default `-DR`; i Resource Group delle altre risorse seguono la stessa regola. La subnet mantiene il nome sorgente. Gli ASG aggiungono il suffisso al nome, ma risiedono nel gruppo della VNet DR.

**Backend pool:** precedenza a `BACKEND_POOL_NAME_OVERRIDE`; poi corrispondenza univoca con il nome sorgente, unico pool DR o unico nome `bepool`/`backendpool`. Se la selezione e ambigua fallisce. Load Balancer multipli sulla NIC sorgente non sono supportati; non vengono riprodotti tutti i pool.

### Esempi delle subscription sorgenti e DR

Tutti i nomi seguenti sono fittizi. Il requisito e un abbinamento per primaria; **il codice attuale usa invece una sola DR globale**. Nell'esempio, `dr_subscription_id` identifica `sub-site-a-DR` e non viene calcolato dal CSV.

| Nome della subscription primaria | Nome della DR richiesta | Destinazione usata oggi con questa configurazione |
|---|---|---|
| `sub-site-a` | `sub-site-a-DR` | `sub-site-a-DR`, selezionata con `TARGET_SUBSCRIPTION_ID`. |
| `sub-site-b` | `sub-site-b-DR` | Ancora `sub-site-a-DR`: il mapping per primaria non e implementato. |

### Esempi dei nomi delle risorse DR

Esempio di una VM di `sub-site-a` ripristinata in `sub-site-a-DR`, con `target_name_suffix=-DR` per i suffissi configurati e `SNAPSHOT_NAME_PREFIX=snap-`. VM, dischi, snapshot e NIC di destinazione risiedono in `rg-site-a-vm-DR`. La naming convention si applica alle risorse Azure, non ai nomi dei computer o delle applicazioni dentro le VM.

| Quale risorsa o riferimento considerare | Nome o valore sorgente di esempio | Nome o valore DR di esempio | Quale regola applica il codice |
|---|---|---|---|
| Resource Group della VM. | `rg-site-a-vm` | `rg-site-a-vm-DR` | Gruppo sorgente + `TARGET_RESOURCE_GROUP_SUFFIX`; deve esistere. |
| Resource Group della VNet. | `rg-site-a-network` | `rg-site-a-network-DR` | Gruppo della VNet sorgente + `TARGET_VNET_RG_SUFFIX`; deve esistere. |
| VNet. | `vnet-site-a` | `vnet-site-a-DR` | Nome sorgente + `TARGET_VNET_NAME_SUFFIX`; deve esistere. |
| Subnet. | `snet-web` | `snet-web` | Stesso nome, nella VNet DR; deve esistere. |
| ASG. | `asg-web` | `asg-web-DR` | Nome sorgente + `TARGET_ASG_NAME_SUFFIX`, nel gruppo della VNet DR. |
| Resource Group del Load Balancer. | `rg-site-a-network` | `rg-site-a-network-DR` | Gruppo del pool sorgente + `TARGET_LB_RG_SUFFIX`; deve esistere. |
| Load Balancer. | `lb-web` | `lb-web-DR` | Nome sorgente + `TARGET_LB_NAME_SUFFIX`; deve esistere. |
| Backend pool. | `backendpool-web` | `backendpool-web` | Esempio di corrispondenza per nome; il pool deve esistere. Nessun suffisso automatico; valgono override/fallback descritti sopra. |
| Frontend IP configuration del Load Balancer. | `frontend-private` | `frontend-private` | Solo esempio di predisposizione: il nome non e calcolato, copiato o verificato dalla Function. |
| Health probe del Load Balancer. | `probe-https` | `probe-https` | Solo esempio di predisposizione: nome e configurazione sono responsabilita del gestore. |
| Regola del Load Balancer. | `rule-https` | `rule-https` | Solo esempio di predisposizione: la Function non replica regole o porte. |
| NSG. | `nsg-web` | `nsg-web-DR` | Solo esempio organizzativo: il codice non deriva questo nome e non copia l'NSG della NIC. |
| Route table. | `rt-web` | `rt-web-DR` | Solo esempio organizzativo: il codice non deriva o copia route table e rotte. |
| Resource Group del DES. | `rg-site-a-security` | `rg-site-a-security-DR` | Gruppo del DES OS sorgente + `TARGET_DES_RG_SUFFIX`; deve esistere. |
| DES. | `des-vm` | `des-vm-DR` | Nome del DES OS sorgente + `TARGET_DES_NAME_SUFFIX`; deve esistere. |
| Key Vault del DES. | `kv-site-a` | `kv-site-a-dr` | Solo esempio: il codice usa il DES DR gia configurato, non calcola o crea il vault. |
| Chiave di cifratura. | `disk-key` | `disk-key` | Solo esempio: nome/versione della chiave sono configurati sul DES DR; non vengono copiati dalla Function. |
| Virtual Machine. | `vm-web-01` | `vm-web-01` | Stesso nome, nel Resource Group DR; nessun `-DR` sulla VM. |
| Disco OS. | `vm-web-01-os` | `vm-web-01-os` | Stesso nome, nel gruppo della VM DR, anche se il disco sorgente era in un altro gruppo. |
| Disco dati, LUN 0. | `vm-web-01-data0` | `vm-web-01-data0` | Stesso nome nel gruppo DR; LUN e caching sono preservati al collegamento. |
| Snapshot del disco OS. | Disco `vm-web-01-os`; non uno snapshot sorgente. | `snap-vm-web-01-os` | `SNAPSHOT_NAME_PREFIX` + nome del disco sorgente, nel gruppo della VM DR. |
| Snapshot del disco dati. | Disco `vm-web-01-data0`; non uno snapshot sorgente. | `snap-vm-web-01-data0` | Stessa regola dello snapshot OS. |
| NIC primaria. | `nic-web-primary` | `vm-web-01-nic` | Nome della VM + `-nic`, non nome NIC sorgente + `-DR`. |
| IP configuration primaria della NIC. | `ipconfig1` | `ipconfig1` | Stesso nome, nella nuova NIC DR. |
| IP privato. | `10.90.1.10` | `10.90.1.10`, statico. | Stesso indirizzo; deve appartenere alla subnet DR ed essere libero. |

Gli esempi organizzativi non introducono requisiti di nome nel codice: frontend, probe, regole, NSG, route table, Key Vault e chiave possono avere altri nomi se la configurazione DR e coerente. Public IP, altre NIC/IP, identita VM ed estensioni non hanno un naming DR derivato dalla Function: non vengono ricopiati esplicitamente.

**Attenzione alle collisioni:** gruppi distinti ma nomi VM uguali restano indistinguibili per l'API di stato, che usa il solo nome VM nel percorso dei log. I nomi degli snapshot sono stabili tra attivazioni: `snap-vm-web-01-os` gia esistente puo essere riusato, non rappresenta automaticamente una nuova copia dei dati.

### Esempi dei nomi dell'hosting Terraform

L'hosting non e un clone del primario e non segue il suffisso DR delle VM. Il nome della Function si imposta in `function_app_name`; gli altri nomi sono personalizzabili nel blocco `resource_names` del tfvars. Le chiavi omesse conservano i default precedenti. La tabella mostra i default con `function_app_name=func-bolla-example`, non una naming convention obbligatoria del cliente.

Le Private DNS zone sono un'eccezione tecnica: i quattro nomi `privatelink.*` identificano i domini dei servizi Azure public cloud e vengono validati. Cambiarli per una naming convention aziendale romperebbe la risoluzione standard di questa configurazione. Sono invece liberi, nei limiti Azure, i nomi di endpoint, link, connessioni e zone group. Non cambiano i nomi degli endpoint API o i nomi DR calcolati dal codice.

| Quale risorsa di hosting considerare | Nome nell'esempio | Da quale input o regola deriva |
|---|---|---|
| Subscription hosting. | `sub-bolla-hosting` | ID fornito in `hosting_subscription_id`; nessun naming derivato. |
| Resource Group hosting. | `rg-bolla-hosting` | Esistente, fornito in `resource_group_name`. |
| Storage Account. | `stbollahostexample` | Esistente, fornito in `storage_account_name`; non rinominato. |
| UAMI sorgente/storage e UAMI DR. | `id-bolla-source`, `id-bolla-dr` | Esistenti, fornite in `source_identity_name` e `target_identity_name`. |
| Function App. | `func-bolla-example` | `function_app_name`. |
| Piano Flex Consumption. | `func-bolla-example-plan` | `resource_names.service_plan`; default nome Function + `-plan`. |
| VNet hosting. | `func-bolla-example-vnet` | `resource_names.virtual_network`; default nome Function + `-vnet`. |
| Subnet di integrazione. | `function-integration` | `resource_names.integration_subnet`. |
| Delega della subnet di integrazione. | `flex-consumption` | `resource_names.integration_subnet_delegation`; il tipo di servizio delegato resta obbligatorio. |
| Subnet dei Private Endpoint. | `private-endpoints` | `resource_names.private_endpoints_subnet`. |
| Private Endpoint Function. | `func-bolla-example-endpoint` | `resource_names.function_private_endpoint`. |
| Private Endpoint Blob, Queue e Table. | `func-bolla-example-storage-blob`, `func-bolla-example-storage-queue`, `func-bolla-example-storage-table` | `resource_names.storage_private_endpoint_blob`, `_queue`, `_table`. |
| Private DNS zone Function. | `privatelink.azurewebsites.net` | `resource_names.function_private_dns_zone`; valore tecnico validato. |
| Private DNS zone Blob, Queue e Table. | `privatelink.blob.core.windows.net`, `privatelink.queue.core.windows.net`, `privatelink.table.core.windows.net` | `resource_names.storage_private_dns_zone_blob`, `_queue`, `_table`; valori tecnici validati. |
| Link delle quattro zone DNS alla VNet. | `hosting-network` | `resource_names.function_private_dns_link` e `storage_private_dns_link_blob`, `_queue`, `_table`; link distinti dentro ogni zona. |
| Connessione privata Function. | `function` | `resource_names.function_private_service_connection`. |
| Connessioni private storage. | `storage-blob`, `storage-queue`, `storage-table` | `resource_names.storage_private_service_connection_blob`, `_queue`, `_table`. |
| Zone group del Private Endpoint Function. | `function` | `resource_names.function_private_dns_zone_group`. |
| Zone group dei Private Endpoint storage. | `storage` | `resource_names.storage_private_dns_zone_group_blob`, `_queue`, `_table`. |
| Container deployment, CSV e log. | `app-package`, `dr-configs`, `dr-logs` | `resource_names.deployment_container`, `csv_container`, `log_container`; nomi distinti propagati a deployment, app settings e output. |
| Application Insights. | `func-bolla-example-insights` | `resource_names.application_insights`. |
| Log Analytics workspace. | `func-bolla-example-logs` | `resource_names.log_analytics_workspace`. |
| Diagnostic setting Function. | `func-bolla-example-diagnostics` | `resource_names.function_diagnostic_setting`. |
| Diagnostic setting Blob, Queue e Table. | `func-bolla-example-blob-diagnostics`, `func-bolla-example-queue-diagnostics`, `func-bolla-example-table-diagnostics` | `resource_names.storage_diagnostic_setting_blob`, `_queue`, `_table`. |

Gli eventuali Resource Group separati di storage/UAMI sono input esistenti, non nomi costruiti: `storage_resource_group_name`, `source_identity_resource_group_name`, `target_identity_resource_group_name`. Non aggiungere `-DR` a queste risorse per farle individuare dalla Function.

Tutte le chiavi complete sono in [terraform/terraform.tfvars.example](terraform/terraform.tfvars.example). Si possono impostare solo quelle necessarie; chiavi sconosciute, nomi vuoti/null, container non validi o duplicati vengono respinti. Il nome della Function e globale; ogni altro nome deve rispettare caratteri, lunghezza e ambito di unicita Azure. Le chiavi `for_each` restano stabili anche con nomi personalizzati.

**Ambienti gia distribuiti:** omettere `resource_names` conserva i nomi originali. Cambiare un nome Azure puo richiedere sostituzione della risorsa e interrompere il servizio; esaminare il piano e autorizzare la migrazione prima di applicarlo. Non usare l'esempio con nomi cliente fittizi come aggiornamento automatico di un ambiente esistente.

## Responsabilita della Function sulle risorse DR

Il codice cerca le risorse nella subscription DR selezionata e nel Resource Group atteso. **Riuso significa continuare con un oggetto esistente dopo i soli controlli sotto**, non aggiornarlo allo stato del primario o certificarne la salute.

| Quale risorsa considera | In quali condizioni la riusa | Come usa o modifica la risorsa esistente | Cosa fa se manca o non corrisponde |
|---|---|---|---|
| Snapshot, stage B. | Trova `<prefisso-snapshot><nome-disco>` nel gruppo DR della VM. Devono coincidere `CreationData.SourceResourceId` con l'ID del disco primario ed `Encryption.DiskEncryptionSetId` con l'ID del DES DR. | Restituisce l'ID dello snapshot con stato interno `Reused`; lo usa come sorgente dei dischi nello stage C. Non crea una nuova copia, non aggiorna lo snapshot e non controlla la sua eta. | Se non trovato, crea lo snapshot con `CreateOption=Copy` e DES DR. Se sorgente o DES differiscono, genera errore; non sovrascrive o elimina quello esistente. |
| Dischi OS e dati, stage C. | Trova il nome del disco sorgente nel gruppo DR della VM. Devono coincidere ID dello snapshot selezionato, `Sku.Name`, ID DES, insieme delle zone e valore numerico `MaxShares`, numero di VM che possono condividere il disco. | Conserva oggetto e ID nel gruppo dei dischi DR. Se crea una nuova VM li collega con caching e LUN, indice del disco dati. Non ricopia dati dal primario e non riallinea proprieta o collegamenti di una VM gia esistente. | Se non trovato, crea dal relativo snapshot con DES/SKU; tier, zone e condivisione sono applicati se supportati. Un confronto fallito genera errore, senza sostituzione o detach automatico. |
| NIC e IP privato, stage D. | Trova `<nome-VM>-nic` nel gruppo DR. Seleziona la IP configuration col nome sorgente, altrimenti la prima. Devono coincidere ID subnet, allocazione `Static` e IP sorgente. Gli ASG sono confrontati solo se almeno un ASG DR e stato trovato; una differenza produce warning, non rifiuto. | Conserva NIC e configurazione IP senza correggere gli ASG, i tag o altre impostazioni. Ne usa l'ID per una nuova VM. Nello stage E puo aggiornare soltanto l'associazione al backend pool previsto. | Se non trovata, crea una NIC con IP sorgente statico e ASG DR trovati. Subnet, allocazione o IP diversi generano errore; ASG mancanti/discordanti possono invece lasciare proseguire il lavoro. |
| Virtual Machine, stage D. | Trova il nome della VM sorgente nel gruppo DR. Controlla soltanto `HardwareProfile.VmSize` e l'ID del managed disk OS, che deve essere quello selezionato nello stage C. | Mantiene la VM senza riconfigurare dischi dati, NIC, tag, identita o boot diagnostics. Non la avvia se e spenta e non controlla provisioning, guest o applicazione. Prosegue verso lo stage E. | Se non trovata, crea con NIC/dischi DR, caching/LUN, nome/dimensione sorgenti, tag e boot diagnostics. Size o disco OS discordanti generano errore; nessuna sostituzione automatica. |
| Associazione NIC/backend pool, stage E. | Se la sorgente usa un Load Balancer, trova Load Balancer/pool DR secondo la selezione descritta sopra. Nella IP configuration col nome sorgente, altrimenti la prima, cerca l'ID del pool tra quelli gia associati. | Se l'ID e gia presente, registra `BackendPoolAlreadyMember` e non aggiorna la NIC. Altrimenti aggiunge il pool ai collegamenti esistenti, salva la NIC e rilegge per verificare la presenza dell'ID. Non crea il pool e non rimuove gli altri pool. | Pool/LB mancanti o selezione ambigua generano errore. Senza LB sorgente salta lo stage di associazione; non rimuove eventuali pool gia presenti sulla NIC riusata. |

Gli ID e le stringhe dei confronti vengono normalizzati per spazi e maiuscole/minuscole; zone e ASG sono confrontati come insiemi, ignorando ordine e duplicati. Non e un confronto completo del modello Azure.

- **Prerequisiti:** Resource Group, VNet/subnet, ASG, Load Balancer/pool e DES devono esistere e sono usati tramite nomi/ID risolti. Regole/probe e Key Vault/chiave restano configurazioni esterne, non risorse create o riconciliate dalla Function.
- **Esiti e risorse parziali:** scrive log per stage e marker finale. Un errore blocca quella replica, ma non esegue rollback delle risorse gia create; altre righe del CSV possono proseguire.
- **Ripetere non significa aggiornare:** un nuovo `invocationId` puo riusare lo stesso snapshot e gli stessi dischi/VM. Non rinnova i dati del ripristino, e i nuovi dischi creati nello stage C non vengono automaticamente collegati a una VM riusata.

I controlli sono in [DRCore.psm1](function-app/Modules/DRCore/DRCore.psm1#L621), nei rami degli stage B-E. `Get-DRStatus` interpreta i log: non crea, corregge o verifica direttamente queste risorse e non distingue una ricostruzione nuova da un riuso sulla base del solo marker di successo.

## Come opera Invoke-DRReplication

`POST /api/Invoke-DRReplication`, autorizzata da function key, riceve `csvBlobPath` nel body JavaScript Object Notation (JSON), formato strutturato della richiesta. Non riceve il CSV direttamente e non predispone i prerequisiti DR. I nomi degli endpoint sono quelli dei relativi [binding](function-app/Invoke-DRReplication/function.json).

| Quale passaggio esegue | Quale operazione compie nel codice attuale |
|---|---|
| 1. Legge richiesta e configurazione. | Richiede `csvBlobPath`, parallelismo VM effettivo 1 e suffissi dalle app settings. Parametro mancante/nessuna riga valida: 400; CSV non trovato: 404. |
| 2. Scarica e valida il CSV con UAMI1. | Legge il container CSV configurato, default `dr-configs`, verifica le tre colonne e scarta righe incomplete con warning. Nessun preflight completo o controllo duplicati. |
| 3. Avvia il lavoro per riga. | Usa un `invocationId` comune, VM sequenziali, UAMI1 nella subscription sorgente della riga e UAMI2 nella DR globale. |
| 4. Stage A: scopre la sorgente. | Legge VM, NIC/IP primari, ASG, pool, dischi OS/dati e DES OS; deriva nomi/gruppi DR. Non congela le scritture applicative. |
| 5. Stage B: snapshot. | UAMI2 copia ogni disco primario in uno snapshot con DES DR, o riusa quello con sorgente/DES corrispondenti. Serve autorizzazione sulla sorgente alla stessa UAMI2. |
| 6. Stage C: dischi. | Crea managed disk dagli snapshot. Per il riuso confronta snapshot, SKU, DES, zone e condivisione, non tutte le proprieta. |
| 7. Stage D: NIC e VM. | Usa subnet/ASG DR, IP statico sorgente, dischi/caching/LUN, nome e dimensione VM sorgenti. Il riuso VM controlla solo dimensione e ID disco OS. |
| 8. Stage E: backend pool. | Se la sorgente ha un Load Balancer, seleziona un pool DR esistente, aggiorna la NIC e verifica l'associazione; altrimenti salta questo collegamento. |
| 9. Registra l'esito. | Scrive log per stage e marker `Completed` o fallimento. Errori per VM possono lasciare risorse parziali; la POST non restituisce gli esiti dettagliati delle VM. |

**Non e un job asincrono persistente:** `Push-OutputBinding` prepara il 202, ma lo script prosegue nella stessa invocazione e risponde quando termina. I commenti di risposta immediata sono inesatti. Il 202 non certifica tutte le VM; dopo un timeout l'esecuzione potrebbe essere ancora attiva.

Fonti del comportamento: [handler HTTP](function-app/Invoke-DRReplication/run.ps1) e [stage A-E in DRCore](function-app/Modules/DRCore/DRCore.psm1).

## Come opera Get-DRStatus

`GET /api/Get-DRStatus?csvBlobPath=...` oppure POST con lo stesso parametro nel body JSON, autorizzate da function key. Usa solo UAMI1 per leggere storage; non chiama UAMI2 per controllare o modificare il DR.

1. Verifica il percorso e scarica il CSV dal container configurato, default `dr-configs`; parametro assente produce 400, CSV non trovato produce 404.
2. Per ogni `SourceVmName` elenca i blob sotto `<container-log>/<nome-VM>/`, default `dr-logs/<nome-VM>/`. Non usa subscription e Resource Group per distinguere VM omonime.
3. Estrae gli `invocationId` dai nomi dei log e sceglie, separatamente per VM, quello con il blob modificato piu recentemente. Non filtra per l'ID della POST richiesta dall'operatore.
4. Interpreta i marker del gruppo selezionato secondo la tabella sotto; un errore di lettura di una VM diventa `ERROR` e le altre possono essere controllate.
5. Restituisce `checkedAt`, `vmCount`, `results` e conteggi in `summary`. Un HTTP 200 significa che la richiesta di stato e stata elaborata, non che tutte le VM siano riuscite.

| Quale stato restituisce | Quale evidenza lo determina |
|---|---|
| `SUCCEEDED` | Esiste un marker `stageCompleted-` non fallito; `completedStage` vale `Completed`. Non verifica provisioning, avvio o salute applicativa. |
| `FAILED` | Non c'e il marker di successo ed esiste un log `-failed.log`; restituisce `failedStage`. Le risorse parziali possono essere ancora presenti. |
| `IN_PROGRESS` | Non c'e ne marker finale ne errore registrato; `lastCompletedStage` indica l'ultimo stage trovato. Non prova che un processo sia ancora attivo. |
| `UNKNOWN` | Non esistono log o il loro formato non e riconosciuto. |
| `ERROR` | La lettura/interpretazione dei log di quella VM genera un errore. |

La risposta e una vista dei log, non un inventario Azure o uno stato autorevole di un job. Un CSV modificato, VM omonime o scritture tardive possono alterare il risultato mostrato. Non certifica Recovery Point Objective (RPO), perdita dati massima ammessa, o Recovery Time Objective (RTO), tempo massimo di ripristino.

Fonti del comportamento: [binding GET/POST](function-app/Get-DRStatus/function.json) e [handler di lettura dello stato](function-app/Get-DRStatus/run.ps1).

## Pre-check prima del deployment

Completare questi controlli prima di applicare Terraform; quelli sui nuovi endpoint si confermano dopo l'apply e prima del deploy del codice.

- [ ] **Risorse e identita:** confermare subscription di hosting, primarie e DR configurata, Resource Group, Storage Account e nomi/client ID/principal ID delle due UAMI. Le subscription coinvolte devono appartenere allo stesso tenant Microsoft Entra ID. I role assignment vanno sull'identita corretta, usando il principal ID; non confondere le due UAMI.
- [ ] **Permessi:** verificare le matrici sotto, gli scope effettivi e la propagazione delle assegnazioni. Controllare anche Azure Policy, deny assignment e resource lock; un ruolo assegnato non supera un divieto della piattaforma.
- [ ] **Storage:** verificare un account StorageV2 che supporti Blob/Queue/Table, TLS 1.2, accesso pubblico/anonimo e shared key disabilitati. Per UAMI1 verificare Blob Data Owner per l'host e Table Data Contributor per la diagnostica host. Queue Data Contributor e suggerito per possibili evoluzioni, non un requisito bloccante dei due trigger HTTP attuali; il supporto del servizio nell'account non prova che la Function lo utilizzi.
- [ ] **Rete e postazione:** predisporre connettivita e DNS verso la nuova VNet. Dopo l'apply verificare Function, nome `scm` di pubblicazione e storage sui rispettivi IP privati. Consentire HTTPS verso autenticazione/management Azure, Terraform Registry e PowerShell Gallery. La sola autenticazione Azure non fornisce accesso privato.
- [ ] **Bolla DR e cifratura:** verificare nomi coerenti con `target_name_suffix`, subnet con gli IP sorgenti liberi, ASG e pool esistenti. DES, VM/dischi/snapshot DR devono essere compatibili per regione/subscription; Key Vault con soft delete e purge protection, chiave attiva e identita DES autorizzata a usarla. Con RBAC usare Key Vault Crypto Service Encryption User sulla chiave/vault, oppure access policy `get`, `wrapKey`, `unwrapKey`. Verificare firewall/trusted services del vault; l'identita DES e distinta dalle UAMI della Function.
- [ ] **Strumenti e disponibilita:** installare Git, Terraform >= 1.9, Azure CLI e PowerShell 7.6. Verificare quota/modello VM in DR e disponibilita regionale di Flex Consumption. Registrare i provider hosting `Microsoft.Web`, `Microsoft.App`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.ManagedIdentity`, `Microsoft.Insights`, `Microsoft.OperationalInsights`; per DR, `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.KeyVault`.

Per un pre-check tracciabile, annotare **identita, ruolo, scope e risultato**. Se manca un controllo, risolverlo prima della fase che ne dipende; non aprire gli endpoint pubblici come workaround.

## Autenticazione e permessi

Role-Based Access Control (RBAC) autorizza le operazioni Azure. Lo **scope** e l'ambito del role assignment; un ruolo sul Resource Group si eredita sulle sue risorse. Le matrici distinguono il ruolo necessario e l'alternativa di scope ammessa, evitando assegnazioni subscription per storage e monitoraggio quando non servono.

### UAMI sorgente/storage

| Quale ruolo verificare | Quale scope usare | Per quale operazione serve |
|---|---|---|
| Storage Blob Data Owner | **Storage Account esistente**; in alternativa il Resource Group che lo contiene. | Ruolo minimo built-in documentato da Microsoft per `AzureWebJobsStorage`, la connessione interna dell'host. Copre anche il pacchetto e i blob del codice. |
| Storage Table Data Contributor | **Lo stesso Storage Account**; in alternativa il suo Resource Group. | Eventi diagnostici dell'host, anche quando l'app non parte. Non e una dipendenza del codice che legge CSV o scrive log Blob. |
| Storage Queue Data Contributor, suggerito e non bloccante | **Lo stesso Storage Account**; in alternativa il suo Resource Group. | Da predisporre se concordato per evoluzioni che usino Queue, Blob trigger o Durable Functions. Non richiesto dalle operazioni HTTP attuali. |
| Reader | Ogni subscription primaria e ogni subscription contenente risorse sorgenti referenziate. | Lettura di VM, dischi, NIC, rete e riferimenti di cifratura. |
| Monitoring Metrics Publisher | **Risorsa Application Insights**; in alternativa il Resource Group che la contiene. | Invio della telemetria autenticata della Function; il ruolo pubblica anche tracce ed eccezioni, non solo metriche. |
| Reader, solo se l'identita deve consultare Application Insights | **Risorsa Application Insights**; in alternativa il suo Resource Group. | Lettura del monitoraggio, non invio della telemetria. |
| Reader, solo se l'identita deve interrogare il workspace | **Risorsa Log Analytics workspace**; in alternativa il suo Resource Group. | Query dei log consentiti; verificare modalita di accesso del workspace ed eventuali restrizioni sulle tabelle. |

**Perche Owner:** CSV/log Blob richiedono al massimo Blob Data Contributor, che puo creare container. UAMI1 usa pero anche `AzureWebJobsStorage`: Owner e il requisito built-in documentato per l'host e copre gia quelle operazioni. Non aggiungere Contributor allo stesso scope. Owner include controlli POSIX sui permessi file/directory, ma il codice non li modifica; non e stata provata un'operazione esclusiva di Owner o l'impossibilita di usare Contributor in ogni esecuzione.

**Quando serve Queue:** per Blob trigger con poison/retry, binding/codice Queue o Durable Functions con provider Azure Storage; il ruolo minimo dipende dall'operazione e puo essere piu stretto di Contributor. Sono casi assenti dai due HTTP trigger attuali. Queue Data Contributor resta suggerito per evoluzioni, non least privilege del runtime: concede gia accesso ai dati. Endpoint/URI presenti in Terraform non provano un uso del servizio; una futura evoluzione richiede revisione di codice, ruoli e rete.

**File share:** Flex Consumption distribuisce il codice dal container Blob e qui non sono configurati mount Azure Files. Non serve un file share o un ruolo Azure Files. Un eventuale mount futuro e opzionale e avrebbe propri prerequisiti.

**Monitoraggio:** Monitoring Metrics Publisher va su Application Insights per l'ingestion; i Reader sono condizionali alla consultazione. Il workspace non sostituisce lo scope Application Insights e non richiede un ruolo di scrittura alla UAMI per questa configurazione.

Application Insights e workspace sono creati da Terraform. Se non esistono ancora, il pre-check puo verificare l'assegnazione sul **Resource Group di hosting gia esistente**; altrimenti predisporre l'assegnazione sulla nuova risorsa subito dopo l'apply e **prima del deploy del codice**. Il gestore RBAC deve essere disponibile per questo passaggio.

### UAMI destinazione/DR

| Quale ruolo verificare | Quale scope usare | Per quale operazione serve |
|---|---|---|
| Reader | Subscription DR e subscription contenenti prerequisiti DR referenziati. | Lettura di rete, DES, Load Balancer e gruppi di destinazione. |
| Virtual Machine Contributor | Subscription DR. | Creazione e gestione di VM e dischi DR. |
| Disk Snapshot Contributor | Subscription DR. | Creazione e gestione degli snapshot DR. |
| Network Contributor | Subscription DR e subscription della rete DR, se diversa. | NIC e collegamenti a subnet, ASG e backend pool. |
| Disk Backup Reader | Ogni subscription primaria contenente i dischi da copiare. | Accesso ai dischi sorgenti necessario alla copia dello snapshot. |

I permessi delle due identita **non si sommano**: la UAMI DR deve avere `Microsoft.Compute/disks/beginGetAccess/action` sulla sorgente, incluso in Disk Backup Reader. Reader da solo non basta. Gli scope subscription DR/primario restano quelli concordati; autorizzano anche risorse estranee alla bolla e devono essere approvati dal gestore.

Il requisito tecnico riguarda i permessi sui dischi sorgenti: Disk Backup Reader puo essere assegnato anche ai soli dischi o ai Resource Group che li contengono. Non aggiungerlo se UAMI2 ha gia permessi equivalenti. L'ambito subscription e una scelta operativa piu ampia, non un requisito della copia. Lo stesso principio vale per Monitoring Metrics Publisher o permessi equivalenti sulla risorsa Application Insights, non sul solo workspace.

### Operatore di deployment

| Quale ruolo verificare | Quale scope usare | Per quale operazione serve |
|---|---|---|
| Contributor | Subscription di hosting; subscription dello storage, se si verificano risorse in altri ambienti. | Terraform, rete/DNS/diagnostica, pubblicazione codice e recupero delle function key. |
| Managed Identity Operator, solo se non gia coperto | Scope delle UAMI, secondo le assegnazioni concordate. | Serve se mancano lettura e assegnazione delle identita alla Function. Non aggiungerlo quando Contributor copre gia le UAMI e queste operazioni. |
| Storage Blob Data Contributor | Subscription dello storage, come previsto per l'operatore. | Upload dei CSV con autenticazione Azure; Contributor non concede da solo i permessi dati Blob. |
| Reader, solo per chi verifica le risorse | Subscription primarie e DR. | Inventario finale; non e richiesto per il solo deployment dell'hosting e non autorizza un reset. |

L'operatore e distinto dalle UAMI. Chi crea i role assignment deve avere Role Based Access Control Administrator, User Access Administrator o Owner negli scope interessati; questi privilegi non servono alla Function. Il reset DR richiede autorizzazione separata e non deve eliminare i prerequisiti.

Gli scope subscription dell'operatore e della UAMI DR sono quelli operativi concordati, non un requisito intrinseco di Azure Functions. Contributor gestisce risorse ma non concede permessi dati Blob: l'upload con `--auth-mode login` richiede il ruolo dati della tabella.

## Struttura del progetto

```text
terraform/        Configurazione AzureRM, variabili, output e file di lock.
terraform/tests/  Test di naming con provider simulato, senza operazioni Azure.
function-app/     Host, due funzioni HTTP, DRCore e dipendenze fissate.
scripts/          build.ps1 e deploy.ps1.
examples/vms.csv  Esempio fittizio della configurazione VM.
out/             Pacchetto generato localmente, escluso da Git.
```

## Deployment della soluzione

Eseguire i comandi in **PowerShell 7.6**, dalla postazione autorizzata con percorso privato. Non cambiare le versioni del provider o dei moduli durante il deployment.

### 1. Scaricare e configurare

```powershell
git clone https://github.com/lupass93/attivazione-dr-bolla.git
Set-Location attivazione-dr-bolla
Copy-Item ./terraform/terraform.tfvars.example ./terraform/terraform.tfvars
az login
```

[terraform/variables.tf](terraform/variables.tf) definisce gli input e non va compilato o modificato per il deployment. Compilare soltanto il file locale `terraform/terraform.tfvars`, copiato da [terraform/terraform.tfvars.example](terraform/terraform.tfvars.example); sostituire i valori fittizi e conservarlo localmente.

| Quali input preparare | Quali valori inserire nel file tfvars |
|---|---|
| `hosting_subscription_id`, `dr_subscription_id` | ID delle subscription hosting e dell'unica DR attualmente configurabile; le subscription primarie sono indicate nel CSV. |
| `resource_group_name`, `storage_account_name` | Nomi del Resource Group e dello Storage Account esistenti. |
| `source_identity_name`, `target_identity_name` | Nomi delle due UAMI esistenti; Terraform ricava client ID e principal ID. |
| `function_app_name` | Nome globale univoco della nuova Function. |
| `resource_names` | Mappa degli override dei nomi risorsa/sotto-risorsa; copiare dall'esempio le sole chiavi richieste dalla naming convention cliente. Ometterla per mantenere tutti i default. |
| `location`, `vnet_address_space`, `integration_subnet_prefix`, `private_endpoints_subnet_prefix` | Regione concordata e rete/subnet non sovrapposte. Non riutilizzare i prefissi di esempio senza verifica. |
| `storage_resource_group_name`, `source_identity_resource_group_name`, `target_identity_resource_group_name` | Solo quando le rispettive risorse non sono nel RG di hosting; altrimenti omettere. |
| `target_name_suffix`, `maximum_instance_count`, `instance_memory_in_mb`, `log_retention_days` | Confermare i default: `-DR`, 10 istanze, 2048 MB e 30 giorni; cambiare solo se necessario e concordato. |

Non esistono altri file di variabili da compilare. Non pubblicare tfvars, stato, piani o CSV reali. Regione/rete/nomi e prerequisiti devono essere disponibili prima dell'attivita.

### 2. Creare l'infrastruttura

```powershell
terraform -chdir=terraform init
terraform -chdir=terraform validate
terraform -chdir=terraform plan -out=deployment.tfplan
terraform -chdir=terraform apply deployment.tfplan
terraform -chdir=terraform output
```

Prima di `apply`, esaminare il piano: nessuna creazione/sostituzione di RG, Storage Account o UAMI esistenti. L'apply genera costi. Dopo l'apply verificare DNS/endpoint privati e ruolo telemetria sul nuovo Application Insights; un piano successivo non deve avere modifiche inattese. Stato e piani possono contenere chiavi lette dal provider: non pubblicarli.

### 3. Creare e pubblicare il pacchetto

```powershell
./scripts/build.ps1
./scripts/deploy.ps1
```

La build scarica i moduli nelle versioni di `function-app/requirements.psd1` e crea `out/function-app.zip`, senza impostazioni locali. Il deploy legge gli output Terraform, rimuove l'eventuale `AzureWebJobsStorage` legacy per usare l'identita, pubblica il codice e verifica i due endpoint: **400 senza CSV e l'esito atteso**, non una replica avviata. Se uno script fallisce, correggere l'errore prima di proseguire. Non usare storage key, `WEBSITE_RUN_FROM_PACKAGE` o accesso pubblico come workaround.

## Configurazione del CSV

Comma-Separated Values (CSV) e un file di colonne separate da virgole. Usare `examples/vms.csv` come modello e compilare queste colonne:

| Quale colonna compilare | Quale valore inserire |
|---|---|
| SourceSubscription | Nome o ID della subscription primaria. |
| SourceResourceGroup | Resource Group della VM sorgente. |
| SourceVmName | Nome esatto della VM sorgente. |

La subscription DR viene da `dr_subscription_id`; `target_name_suffix`, default `-DR`, determina i nomi dei prerequisiti DR, non una destinazione subscription per riga. La regione della replica e quella del DES DR. VM e dischi mantengono i nomi sorgenti; gli IP privati vengono riutilizzati. Confermare nomi e IP prima dell'attivazione.

Nella cartella del repository, leggere gli output e caricare il CSV reale preparato localmente:

```powershell
$Outputs = terraform -chdir=terraform output -json | ConvertFrom-Json
$Subscription = $Outputs.hosting_subscription_id.value
$ResourceGroup = $Outputs.resource_group_name.value
$FunctionName = $Outputs.function_app_name.value
$ApiUrl = $Outputs.api_url.value
$StorageAccount = $Outputs.storage_account_name.value
$CsvContainer = $Outputs.csv_container_name.value
$CsvBlobPath = 'configurations/my-vms.csv'
az storage blob upload --account-name $StorageAccount --container-name $CsvContainer --name $CsvBlobPath --file ./my-vms.csv --auth-mode login --overwrite
```

L'upload usa l'identita dell'operatore e sovrascrive solo quel blob. Non pubblicare il CSV reale o credenziali nel repository.

## Attivazione e verifica

Le Application Programming Interface (API) sono gli endpoint HTTP della Function. La function key e un segreto condiviso: recuperarla in memoria e inviarla nell'header, non nell'URL.

### Invoke-DRReplication

```powershell
$FunctionKey = az functionapp keys list --subscription $Subscription --resource-group $ResourceGroup --name $FunctionName --query functionKeys.default -o tsv
$Headers = @{ 'x-functions-key' = $FunctionKey }
$Body = @{ csvBlobPath = $CsvBlobPath } | ConvertTo-Json
$Activation = Invoke-RestMethod -Method Post -Uri "$ApiUrl/Invoke-DRReplication" -Headers $Headers -ContentType 'application/json' -Body $Body -TimeoutSec 300 -StatusCodeVariable ActivationCode
$ActivationCode
$Activation | Format-List invocationId, vmCount, startedAt, message
```

La POST crea o riusa risorse DR. La risposta **202 arriva dopo l'elaborazione** e non prova il successo di ogni VM. Ogni chiamata genera un nuovo `invocationId`, condiviso dalle VM del suo CSV. Il parallelismo VM deve essere 1; iniziare con CSV piccoli e chiamate sequenziali.

### Get-DRStatus

```powershell
$Status = Invoke-RestMethod -Method Get -Uri "$ApiUrl/Get-DRStatus?csvBlobPath=$CsvBlobPath" -Headers $Headers
$Status.summary | Format-List
$Status.results | Format-Table vmName, status, invocationId, completedStage, lastCompletedStage, failedStage
```

La GET legge i log, non avvia la bolla. Per ogni VM seleziona l'esecuzione con il log modificato piu recentemente: **confrontare l'ID con `$Activation.invocationId`**; non esiste un filtro per ID. `SUCCEEDED` richiede il marker finale; `FAILED` indica uno stage fallito; `IN_PROGRESS` non prova che un processo interrotto sia ancora attivo; `UNKNOWN` significa log assenti/non riconoscibili; `ERROR` indica errore di lettura. Controllare anche VM, dischi, NIC e servizio applicativo.

## Limiti e troubleshooting

| Quale limite esiste oggi | Quale rischio comporta |
|---|---|
| Una sola subscription DR globale. | Non soddisfa primaria A -> A-DR e primaria B -> B-DR. Non usare il suffisso come se quel mapping fosse gia implementato. |
| Elaborazione dentro la richiesta HTTP, senza job persistente. | Il frontend puo perdere la risposta oltre circa 230 secondi. `functionTimeout=-1` non elimina riavvii, scale-in o aggiornamenti della piattaforma; non garantisce un'esecuzione infinita. |
| Nessun lock tra richieste o istanze. | `vmParallelThrottle=1` e `http_concurrency=1` limitano il lavoro locale, non escludono attivazioni sovrapposte sullo stesso workload. |
| Snapshot e dischi riusati non sono aggiornati dal primario. | Sorgente/DES uguali non provano freschezza o integrita dei dati; nessun controllo di eta, provisioning o readiness dello snapshot. Per il disco non vengono confrontati dimensione, tier o attuale utilizzo/collegamento. Una nuova POST puo continuare con dati precedenti. |
| Riuso VM limitato a size e disco OS. | Una VM spenta o con provisioning fallito puo superare questi controlli; NIC/dischi dati previsti, identita, tag e salute non vengono riconciliati. I dischi creati nello stage C possono restare non collegati alla VM riusata. |
| Ricerca per nome senza verifica completa di appartenenza. | Il codice non richiede marcatori di proprieta del job o del workload per adottare risorse esistenti. Una NIC collegata ad altra VM o un disco in uso non sono respinti preventivamente dai controlli di riuso. |
| Snapshot per disco senza coordinare le scritture. | Nessuna consistenza applicativa/multi-disco garantita, replica continua o RPO/RTO misurati. Nessuna pipeline cross-region implementata. |
| Topologia e proprieta VM solo parzialmente ricostruite. | Una NIC e una IP configuration vengono ricreate; gli ASG trovati sulle configurazioni della NIC sorgente vengono raccolti sulla configurazione DR. NSG della NIC, altre NIC/IP, security profile, identita VM ed estensioni non sono ricopiati esplicitamente; zona VM e disk controller non sono impostati esplicitamente. |
| NIC/pool non vengono riconciliati completamente. | Configurazione IP scelta per nome o prima disponibile; ASG discordanti non corretti e confronto saltato se nessun ASG DR e trovato. Aggiungere il pool desiderato conserva quelli precedenti; senza LB sorgente non li rimuove. Un esito positivo non certifica policy o traffico coerenti. |
| Lookup di riuso con `ErrorAction=SilentlyContinue`. | Snapshot, dischi, NIC e VM possono non restituire un oggetto anche per problemi di lettura. Il ramo di creazione non distingue esplicitamente risorsa assente da lookup fallito; rischia tentativi impropri, conflitti e diagnosi ambigue. |
| Stato ricavato dai nomi dei log, indicizzati per solo nome VM. | VM omonime si confondono; vecchie esecuzioni con scritture tardive possono risultare le piu recenti. L'upload log fallito viene trattato come warning: risorse create ed esito mostrato possono divergere. |
| Nessun preflight completo o rollback. | Righe incomplete vengono scartate, duplicati e risorse fuori ambito non sono respinti preventivamente. Errori possono lasciare risorse parziali; i retry ripetono anche alcuni errori di autorizzazione/configurazione. |
| Function key condivisa e identita con ambiti subscription. | Il client non ha autorizzazione applicativa per identita/singolo workload; i permessi delle UAMI possono coprire risorse oltre la bolla. Ingresso privato non dimostra isolamento dell'uscita o delle VM DR. |
| Nessuno smantellamento, retention dei log Blob o test automatici del flusso DR nel repo target. | Pulizia, costi e conservazione dei dati richiedono procedure esterne. Parser/build, smoke check e test Terraform di naming non verificano replica completa o resistenza ai guasti. |

**Condotta attuale:** usare CSV piccoli, autorizzati e senza VM omonime, chiamate sequenziali e prerequisiti verificati. Dopo un timeout non ripetere la POST prima di verificare l'esecuzione precedente. Confrontare gli ID dei log, controllare direttamente risorse/avvio e provare il servizio applicativo. Sono mitigazioni operative, non una soluzione ai limiti sopra.

| Quale errore compare | Quale controllo effettuare |
|---|---|
| 400 | Parametro CSV assente, nessuna riga valida o parallelismo effettivo diverso da 1. Non tutti gli input malformati producono 400. |
| 401 | Function key mancante o errata. |
| 403 o endpoint non raggiungibile | Permessi, percorso privato e DNS; non aprire l'accesso pubblico. |
| 404 | Percorso CSV/blob nel container CSV configurato, mostrato dall'output `csv_container_name`. |
| 500 | Log della Function e caricamento dei moduli; non cambiare le versioni fissate. |
| LinkedAuthorizationFailed / beginGetAccess | Disk Backup Reader della **UAMI DR sulla sorgente**, non solo Reader dell'altra identita. |
| AuthorizationFailed | Identita effettiva, ruolo, scope, deny assignment/policy/lock dell'operazione. |

## Migliorie prioritarie e verifiche

Le seguenti sono proposte, non funzionalita presenti. **Prima dell'uso enterprise** indica correzioni necessarie per il requisito multi-DR e per attivazioni governate; le altre dipendono dagli obiettivi di disponibilita, sicurezza e recupero concordati. Una garanzia richiede test e prove, non la sola presenza di istruzioni nel README.

| Quando intervenire | Quale modifica proporre | Quale prova ne verifica l'efficacia |
|---|---|---|
| Prima dell'uso enterprise. | Risolvere per riga nome primario + `-DR` in un ID DR univoco e autorizzato; poi eliminare la DR globale. | Due primarie raggiungono solo le rispettive DR; mapping assente/ambiguo blocca le scritture. |
| Prima dell'uso enterprise. | Separare HTTP starter e job con Queue/worker o Durable Functions, workflow persistente; restituire ID/URL di stato e conservare stato, checkpoint e versione CSV. Verificare compatibilita, ruoli e costi. | Job oltre 230 secondi interrogabile per ID, anche dopo timeout/riavvio o scritture tardive. |
| Prima dell'uso enterprise. | Chiave di idempotenza, lock distribuito per subscription/gruppo/VM e contesti Azure espliciti per tutte le operazioni. | POST sovrapposte non duplicano il workload e non cambiano contesto di operazioni altrui. |
| Prima dell'uso enterprise. | Validare CSV, dimensione/numero/unicita righe e ambiti autorizzati; preflight di permessi, nomi/IP, prerequisiti, quota e operazioni previste. | Riga vietata, IP occupato o prerequisito mancante: errore esplicito e zero creazioni. |
| Prima dell'uso enterprise. | Definire separatamente ripresa della stessa attivazione e ripristino con dati nuovi. Per ogni risorsa registrare ID, sorgente e generazione del restore; verificare stato e appartenenza prima del riuso. | La ripresa conserva la generazione prevista; un nuovo ripristino non usa silenziosamente vecchi snapshot. Risorse estranee, occupate o non pronte sono respinte. |
| Prima dell'uso enterprise. | Verificare tutti i dischi/caching/LUN, NIC e collegamenti della VM riusata; dimensione/tier/collegamento dei dischi, stato snapshot/VM e avvio richiesto. Riparazioni solo esplicite e autorizzate, senza detach o cancellazioni automatiche. | VM spenta/fallita e modello discordante non producono successo; dischi creati e NIC prevista sono realmente associati alla VM corretta. |
| Prima dell'uso enterprise. | Bloccare ASG obbligatori mancanti/discordanti; selezionare esplicitamente IP configuration e pool, verificando anche collegamenti non previsti. Non rimuoverli senza ownership e approvazione. | ASG errati o pool aggiuntivi inattesi impediscono il successo; nessuna alterazione di traffico o risorse estranee. |
| Prima dell'uso enterprise. | Distinguere lookup 404, assenza confermata, 403 ed errori transienti. Creare solo dopo assenza verificata e ricontrollare il modello dopo conflitti/concorrenza. | Lettura negata non avvia creazione; due attivazioni concorrenti non adottano risorse discordanti o duplicano le operazioni. |
| In base a RPO/RTO. | Policy di freschezza e consistenza; quiescing, sospensione controllata delle scritture, o protezione application-aware. Copia cross-region e strategia zonale solo se richieste. | Restore drill con perdita dati, tempi e integrita misurati sulla topologia prevista. |
| In base alla fedelta richiesta. | Formalizzare proprieta da preservare e differenze intenzionali: controller, security profile, zone, identita, NIC/IP ed estensioni. | Modelli sorgente/DR conformi a ogni proprieta richiesta e alle differenze approvate. |
| In base alle policy di sicurezza. | Microsoft Entra per caller e autorizzazione per workload; least privilege, endpoint privati, uscita e accesso CSV/log controllati; approvazione delle operazioni distruttive. | Caller/destinazioni vietati respinti; test negativi dei limiti di rete e permessi. |
| In base a gestione e costi. | Retry solo per errori transienti, checkpoint, cleanup su soli ID del job, retention snapshot/log e alert per attivazione. | Guasti rilevati e residui censiti; cleanup conserva sorgenti, prerequisiti e risorse estranee. |
| A ogni modifica. | Test automatici con Azure mock e ambiente dedicato per mapping, stati, riuso, errori e concorrenza; pipeline con secret scanning e verifica dipendenze. | Regressioni/segreti bloccati; guasti e ripristino verificati, non solo esiti HTTP. |

Punto di partenza piu semplice: correggere routing multi-DR e preflight, rendere univoci job e stato, impedire sovrapposizioni. Una riscrittura o servizi aggiuntivi vanno introdotti solo per coprire requisiti confermati, con costo operativo esplicito. Queste proposte non sono ancora implementate.

## Riferimenti

- Codice che decide creazione/riuso e collegamenti DR: [DRCore.psm1](function-app/Modules/DRCore/DRCore.psm1). Le fonti Microsoft spiegano la piattaforma, non certificano automaticamente questa implementazione.
- Flussi e stati delle API: [Invoke-DRReplication/run.ps1](function-app/Invoke-DRReplication/run.ps1) e [Get-DRStatus/run.ps1](function-app/Get-DRStatus/run.ps1).
- Hosting, autenticazione, packaging e smoke check: [terraform/main.tf](terraform/main.tf), [function-app/host.json](function-app/host.json), [scripts/build.ps1](scripts/build.ps1) e [scripts/deploy.ps1](scripts/deploy.ps1).
- [Modello di struttura](https://github.com/stefze/Attivazione-Bolla/blob/main/README.md); le istruzioni sopra riguardano questa versione, non il deployment Bicep/azd del sorgente.
- [Vincoli di naming Azure per tipo di risorsa](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules): caratteri, lunghezze e ambito di unicita si verificano dopo aver aggiunto suffissi/prefissi.
- [Private DNS zone dei servizi Azure](https://learn.microsoft.com/azure/private-link/private-endpoint-dns#commercial): domini tecnici da preservare nella configurazione public cloud.
- [Scope RBAC](https://learn.microsoft.com/azure/role-based-access-control/scope-overview) e [ruoli dati Storage](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/storage).
- [Requisiti host e condizioni delle estensioni](https://learn.microsoft.com/azure/azure-functions/manage-connections?pivots=functions-auth-identity&tabs=host#grant-permissions-to-an-identity): Blob Data Owner, diagnostica Table e casi Queue.
- [Uso dei servizi storage](https://learn.microsoft.com/azure/azure-functions/storage-considerations?pivots=flex-consumption-plan): account compatibile, deployment Blob e differenze tra piani.
- [Definizione Contributor](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/privileged#contributor): gestione risorse, senza permessi dati Blob o gestione dei role assignment.
- [Application Insights: telemetria autenticata e Monitoring Metrics Publisher](https://learn.microsoft.com/azure/azure-monitor/app/azure-ad-authentication).
- [Log Analytics: controllo dell'accesso ai log](https://learn.microsoft.com/azure/azure-monitor/logs/manage-access).
- [Ruoli compute e Disk Backup Reader](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/compute) e [Managed Identity Operator](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/identity).
- [Networking Azure Functions](https://learn.microsoft.com/azure/azure-functions/functions-networking-options), [deployment Flex](https://learn.microsoft.com/azure/azure-functions/deployment-zip-push?pivots=flex-consumption-plan) e [timeout](https://learn.microsoft.com/azure/azure-functions/functions-scale#function-app-timeout-duration).
- [Output binding PowerShell](https://learn.microsoft.com/azure/azure-functions/functions-reference-powershell#bindings) e [pattern HTTP di Durable Functions](https://learn.microsoft.com/azure/durable-task/durable-functions/durable-functions-http-features#expose-http-apis).
- [Snapshot e consistenza dei dati](https://learn.microsoft.com/azure/virtual-machines/backup-and-disaster-recovery-for-azure-iaas-disks) e [copia snapshot tra regioni](https://learn.microsoft.com/azure/virtual-machines/disks-copy-incremental-snapshot-across-regions).
- [Sicurezza degli endpoint Functions](https://learn.microsoft.com/azure/azure-functions/security-concepts#secure-operation): function key, autenticazione dei client e least privilege.
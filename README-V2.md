# Attivazione Bolla - DR Replication Function

Azure Functions privata, PowerShell 7.6 e piano Flex Consumption: legge un CSV da Azure Storage e ricrea Virtual Machine (VM) nel Disaster Recovery (DR), cioe l'ambiente di ripristino. Terraform usa solo AzureRM; due User-Assigned Managed Identity (UAMI), identita Azure senza password, separano letture/storage e operazioni DR.

> Versione 2 proposta per confronto. Non sostituisce il README attuale e non modifica il software. Deriva dalla copia corretta di [stefze/Attivazione-Bolla](https://github.com/stefze/Attivazione-Bolla).

## Indice

- [Architettura e risorse](#architettura-e-risorse)
- [Pre-check prima del deployment](#pre-check-prima-del-deployment)
- [Autenticazione e permessi](#autenticazione-e-permessi)
- [Struttura del progetto](#struttura-del-progetto)
- [Deployment della soluzione](#deployment-della-soluzione)
- [Configurazione del CSV](#configurazione-del-csv)
- [Attivazione e verifica](#attivazione-e-verifica)
- [Limiti e troubleshooting](#limiti-e-troubleshooting)
- [Riferimenti](#riferimenti)

## Architettura e risorse

`Invoke-DRReplication` legge il CSV, individua VM/rete/dischi sorgenti, crea snapshot e dischi cifrati, ricrea NIC e VM e collega i backend pool. Una Network Interface (NIC) e l'interfaccia di rete della VM. `Get-DRStatus` legge CSV e log senza creare risorse.

| Quali risorse devono gia esistere | Quali risorse crea Terraform |
|---|---|
| Resource Group di hosting, Storage Account StorageV2 e due UAMI. | Piano Flex Consumption, Function privata, rete di hosting e due subnet separate. |
| Nel DR: gruppi workload, VNet/subnet, ASG, Load Balancer/backend pool e DES con Key Vault/chiave. | Private Endpoint della Function e dei servizi Blob/Queue/Table, con zone DNS private. |
| Postazione con percorso di rete verso i servizi privati. | Container `app-package`, `dr-configs`, `dr-logs`, Application Insights, Log Analytics workspace e diagnostica. |

Virtual Network (VNet) e la rete privata; Application Security Group (ASG) raggruppa interfacce nelle regole di sicurezza. Disk Encryption Set (DES) collega i dischi alla chiave di cifratura. Un Private Endpoint rende raggiungibile un servizio tramite IP privato; il Domain Name System (DNS) deve risolvere il nome del servizio in quell'IP.

Terraform non crea o assegna i ruoli delle identita e non gestisce Resource Group, Storage Account o UAMI preesistenti. Nella configurazione attuale questi quattro prerequisiti devono appartenere alla subscription di hosting; possono essere in Resource Group differenti.

## Pre-check prima del deployment

Completare questi controlli prima di applicare Terraform; quelli sui nuovi endpoint si confermano dopo l'apply e prima del deploy del codice.

- [ ] **Risorse e identita:** confermare subscription di hosting, primaria e DR, Resource Group, Storage Account e nomi/client ID/principal ID delle due UAMI. Le subscription coinvolte devono appartenere allo stesso tenant Microsoft Entra ID. I role assignment vanno sull'identita corretta, usando il principal ID; non confondere le due UAMI.
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

**Perche Owner:** per la sola lettura del CSV e scrittura dei log applicativi basterebbe Storage Blob Data Contributor, che include anche creazione/modifica dei container e dei blob. In questo progetto la stessa UAMI1 autentica l'host verso `AzureWebJobsStorage`: manteniamo quindi Storage Blob Data Owner come requisito documentato Microsoft, non perche Contributor non possa creare container. Non occorre aggiungere anche Blob Data Contributor allo stesso scope quando Owner e gia presente.

Storage Blob Data Owner include privilegi piu ampi, fra cui i controlli di accesso POSIX, il modello di permessi su file e directory. Il codice di questa soluzione non modifica tali permessi. La documentazione consultata non identifica una specifica operazione esclusiva di Owner eseguita qui: non abbiamo quindi provato che Contributor fallirebbe in ogni esecuzione. Il test del lab dimostra il funzionamento dell'insieme di ruoli assegnato, non l'indispensabilita di ciascuna sua voce; non e stato eseguito un test con ruoli revocati.

**Quando serve Queue:** l'accesso al servizio serve per gestione poison/retry dei Blob trigger, per binding/codice che lavorano su queue e per Durable Functions con il provider Azure Storage. Il ruolo minimo dipende dall'operazione: un Queue trigger o un solo invio possono usare ruoli piu stretti di Contributor. Questa app usa solo HTTP trigger e non contiene tali condizioni. Suggerire Queue Data Contributor per evoluzioni resta una scelta preventiva concordata, non least privilege del runtime attuale: il ruolo consente gia operazioni sui dati Queue nello scope. Terraform configura gia l'endpoint privato e l'URI Queue, ma la loro presenza non prova una dipendenza del runtime. Una futura evoluzione richiede comunque revisione di binding, connessioni, ruoli e rete; il ruolo da solo non la implementa.

**File share:** Flex Consumption distribuisce il codice dal container Blob e qui non sono configurati mount Azure Files. Non serve un file share o un ruolo Azure Files. Un eventuale mount futuro e opzionale e avrebbe propri prerequisiti.

**Application Insights e Log Analytics non sono scope intercambiabili:** Monitoring Metrics Publisher va su Application Insights per l'ingestion; Reader sul workspace serve alla consultazione dei suoi log. I due Reader di monitoraggio sono condizionali: non sono richiesti alla UAMI solo per eseguire la replica o inviare telemetria. La configurazione di questa Function non richiede un ruolo di scrittura sul workspace.

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
| `hosting_subscription_id`, `dr_subscription_id` | ID delle subscription hosting e DR; la subscription primaria e indicata nel CSV. |
| `resource_group_name`, `storage_account_name` | Nomi del Resource Group e dello Storage Account esistenti. |
| `source_identity_name`, `target_identity_name` | Nomi delle due UAMI esistenti; Terraform ricava client ID e principal ID. |
| `function_app_name` | Nome globale univoco della nuova Function. |
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

La subscription DR viene da `dr_subscription_id`; `target_name_suffix`, default `-DR`, determina i nomi dei prerequisiti DR. La regione della replica e quella del DES DR. VM e dischi mantengono i nomi sorgenti; gli IP privati vengono riutilizzati. Confermare nomi e IP prima dell'attivazione.

Nella cartella del repository, leggere gli output e caricare il CSV reale preparato localmente:

```powershell
$Outputs = terraform -chdir=terraform output -json | ConvertFrom-Json
$Subscription = $Outputs.hosting_subscription_id.value
$ResourceGroup = $Outputs.resource_group_name.value
$FunctionName = $Outputs.function_app_name.value
$ApiUrl = $Outputs.api_url.value
$StorageAccount = $Outputs.storage_account_name.value
$CsvBlobPath = 'configurations/my-vms.csv'
az storage blob upload --account-name $StorageAccount --container-name dr-configs --name $CsvBlobPath --file ./my-vms.csv --auth-mode login --overwrite
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
$Status.results | Format-Table vmName, status, invocationId, completedStage, failedStage
```

La GET legge i log, non avvia la bolla. Per ogni VM seleziona l'esecuzione con il log modificato piu recentemente: **confrontare l'ID con `$Activation.invocationId`**; non esiste un filtro per ID. `SUCCEEDED` richiede il marker finale; `FAILED` indica uno stage fallito; `IN_PROGRESS` non prova che un processo interrotto sia ancora attivo; `UNKNOWN` significa log assenti/non riconoscibili; `ERROR` indica errore di lettura. Controllare anche VM, dischi, NIC e servizio applicativo.

## Limiti e troubleshooting

- Il frontend HTTP puo perdere la risposta dopo circa 230 secondi, anche con timeout locale 300 e durata Function illimitata. **Non ripetere la POST dopo un timeout** senza verificare che la precedente esecuzione sia conclusa.
- Gli snapshot non coordinano le scritture applicative; il riuso non ne verifica l'eta e non valida tutta la VM. Non eseguire chiamate concorrenti sugli stessi nomi.
- La VM DR non ha zona impostata esplicitamente. ASG mancanti producono warning; i log e i probe non certificano salute o consistenza applicativa.
- Non esiste un'API di smantellamento; cancellare i cloni e un'attivita amministrativa separata. VM, dischi, snapshot e monitoring generano costi finche rimangono attivi o conservati.

| Quale errore compare | Quale controllo effettuare |
|---|---|
| 400 | CSV assente/non valido o parallelismo diverso da 1. |
| 401 | Function key mancante o errata. |
| 403 o endpoint non raggiungibile | Permessi, percorso privato e DNS; non aprire l'accesso pubblico. |
| 404 | Percorso CSV/blob nel container `dr-configs`. |
| 500 | Log della Function e caricamento dei moduli; non cambiare le versioni fissate. |
| LinkedAuthorizationFailed / beginGetAccess | Disk Backup Reader della **UAMI DR sulla sorgente**, non solo Reader dell'altra identita. |
| AuthorizationFailed | Identita effettiva, ruolo, scope, deny assignment/policy/lock dell'operazione. |

## Riferimenti

- [Modello di struttura](https://github.com/stefze/Attivazione-Bolla/blob/main/README.md); le istruzioni sopra riguardano questa versione, non il deployment Bicep/azd del sorgente.
- [Scope RBAC](https://learn.microsoft.com/azure/role-based-access-control/scope-overview) e [ruoli dati Storage](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/storage).
- [Requisiti host e condizioni delle estensioni](https://learn.microsoft.com/azure/azure-functions/manage-connections?pivots=functions-auth-identity&tabs=host#grant-permissions-to-an-identity): Blob Data Owner, diagnostica Table e casi Queue.
- [Uso dei servizi storage](https://learn.microsoft.com/azure/azure-functions/storage-considerations?pivots=flex-consumption-plan): account compatibile, deployment Blob e differenze tra piani.
- [Definizione Contributor](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/privileged#contributor): gestione risorse, senza permessi dati Blob o gestione dei role assignment.
- [Application Insights: telemetria autenticata e Monitoring Metrics Publisher](https://learn.microsoft.com/azure/azure-monitor/app/azure-ad-authentication).
- [Log Analytics: controllo dell'accesso ai log](https://learn.microsoft.com/azure/azure-monitor/logs/manage-access).
- [Ruoli compute e Disk Backup Reader](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/compute) e [Managed Identity Operator](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/identity).
- [Networking Azure Functions](https://learn.microsoft.com/azure/azure-functions/functions-networking-options), [deployment Flex](https://learn.microsoft.com/azure/azure-functions/deployment-zip-push?pivots=flex-consumption-plan) e [timeout](https://learn.microsoft.com/azure/azure-functions/functions-scale#function-app-timeout-duration).
# Attivazione della bolla Disaster Recovery con Azure Functions

Questo progetto crea l'hosting di una Azure Function App privata e pubblica due funzioni PowerShell per ricreare Virtual Machine (VM) in un ambiente Disaster Recovery (DR). Terraform usa soltanto il provider AzureRM. PowerShell 7.6 esegue il codice applicativo.

Questa versione locale modificata deriva da [stefze/Attivazione-Bolla](https://github.com/stefze/Attivazione-Bolla). Il responsabile della pubblicazione ha confermato il diritto di redistribuire questa copia; non viene aggiunta una licenza non presente nel sorgente. Il test ha verificato hosting privato, due identita, quattro VM nuove dopo un reset delimitato, dieci dischi/snapshot cifrati e lettura coerente dei log. Non certifica la consistenza delle applicazioni o il loro servizio HTTP/HTTPS.

## Quali risorse devono esistere prima di Terraform

- Un Resource Group, cioe il contenitore Azure in cui creare il nuovo hosting.
- Uno Storage Account di tipo StorageV2 con servizi Blob, Queue e Table. Lo storage conserva pacchetto, configurazioni CSV, log e informazioni di funzionamento dell'host. L'accesso pubblico e le shared key, chiavi condivise dell'account, non servono alla soluzione.
- Due User-Assigned Managed Identity (UAMI), risorse identita Azure senza password, con ruoli gia assegnati.
- Nella subscription DR: gruppi workload, Virtual Network (VNet), subnet, Application Security Group (ASG), Load Balancer e Disk Encryption Set (DES) con la configurazione di cifratura. La VNet e la rete privata; gli ASG raggruppano le NIC nelle regole di sicurezza; il DES collega i dischi alle chiavi di cifratura predisposte. Questi prerequisiti DR non vengono creati dal Terraform di hosting.
- Una postazione con accesso alla rete privata della nuova Function e dello storage, con Domain Name System (DNS) che risolve i nomi dei servizi nei loro indirizzi privati. La sola autenticazione Azure non fornisce questa connessione.

Le subscription sorgenti e DR devono appartenere allo stesso tenant Microsoft Entra ID, il servizio Azure che gestisce le identita. Il codice richiede dischi gestiti e cifratura del disco OS tramite DES. Replica la NIC primaria e la sua IP configuration primaria, non tutte le NIC di una VM.

## Quale identita usa ogni operazione

Role-Based Access Control (RBAC) e il controllo Azure che autorizza un'identita a eseguire determinate operazioni. Lo scope e l'ambito dell'assegnazione: un ruolo sulla subscription si eredita sulle risorse contenute. Per il deployment cliente descritto qui le assegnazioni sono a livello subscription, come previsto dal contesto di utilizzo, non limitate al Resource Group della Function. Quando hosting, storage, identita o primario sono in subscription diverse, assegnare i ruoli nelle rispettive subscription.

| Quale identita viene selezionata | Quale ruolo deve essere gia assegnato | In quale subscription si assegna | Quali operazioni autorizza |
|---|---|---|---|
| UAMI sorgente/storage | Storage Blob Data Owner | Subscription dello storage esistente | Legge CSV e pacchetto, scrive log e gestisce i blob utilizzati dall'host. |
| UAMI sorgente/storage | Storage Queue Data Contributor | Subscription dello storage esistente | Accede alle queue utilizzate dall'host. |
| UAMI sorgente/storage | Storage Table Data Contributor | Subscription dello storage esistente | Accede alle table dello storage host. |
| UAMI sorgente/storage | Reader | Ogni subscription primaria e ogni subscription che contiene risorse sorgenti referenziate | Legge VM, dischi, NIC, rete e riferimenti di cifratura del primario. |
| UAMI sorgente/storage | Reader e Monitoring Metrics Publisher | Subscription di hosting e di Application Insights, se diversa | Legge il contesto di hosting e invia telemetria autenticata ad Application Insights. |
| UAMI destinazione | Reader | Subscription DR e altre subscription che contengono i prerequisiti DR referenziati | Legge gruppi, DES, rete e Load Balancer di destinazione. |
| UAMI destinazione | Virtual Machine Contributor | Subscription DR | Crea e aggiorna VM, dischi e risorse compute della bolla. |
| UAMI destinazione | Disk Snapshot Contributor | Subscription DR | Crea, legge e gestisce gli snapshot di destinazione. |
| UAMI destinazione | Network Contributor | Subscription DR e subscription di rete DR, se diversa | Crea le NIC e collega subnet, ASG e backend pool del Load Balancer. |
| UAMI destinazione | Disk Backup Reader | Ogni subscription primaria contenente i dischi da copiare | Legge i dischi e autorizza l'accesso ai dati necessario alla copia dello snapshot. |

I permessi di due identita non si sommano nella stessa richiesta Azure. UAMI2 deve possedere `Microsoft.Compute/disks/beginGetAccess/action` sulla sorgente: Reader da solo non basta. Il ruolo Disk Backup Reader include lettura ed export del disco, non la sua modifica o quella della VM. La prova ha restituito `LinkedAuthorizationFailed` senza questo ruolo ed e riuscita dopo l'assegnazione approvata. Nel test il ruolo e stato limitato ai dieci dischi; nel contesto cliente la matrice sopra richiede scope subscription.

Un'assegnazione subscription e piu ampia: Disk Backup Reader permette l'export di tutti i dischi nell'ambito, mentre i ruoli Contributor DR permettono modifiche anche a risorse estranee alla bolla. Il gestore delle subscription deve approvare questo ambito, separare le due identita e verificare deny assignment, Azure Policy, condizioni dei ruoli e resource lock, che possono negare un'operazione anche in presenza di un ruolo. Non utilizzare Owner sulle UAMI come sostituto generico dei ruoli elencati.

Terraform non crea le identita o i loro ruoli workload. Il codice configura `SOURCE_IDENTITY_CLIENT_ID` e `TARGET_IDENTITY_CLIENT_ID`, gli identificativi delle identita selezionate; legge il primario con la prima e lavora in DR con la seconda. Gli upload dei log mantengono il contesto storage della prima identita.

## Quali permessi servono all'operatore

L'operatore che esegue Terraform e il deploy usa un'identita diversa dalle due UAMI. I suoi ruoli devono essere gia assegnati prima dei comandi del README.

| Quale ruolo usa l'operatore | In quale subscription si assegna | Per quale fase serve |
|---|---|---|
| Contributor | Subscription di hosting e subscription dello storage esistente, se diversa | Legge i prerequisiti, crea hosting/rete/DNS/monitoring/container, configura diagnostica, pubblica codice e recupera le function key. Il data source storage puo leggere le chiavi nello state, anche se non vengono utilizzate per l'autenticazione applicativa. |
| Managed Identity Operator | Subscription delle due UAMI, quando non gia coperta da Contributor | Consente di assegnare le UAMI esistenti alla nuova Function; non consente di creare assegnazioni RBAC. |
| Storage Blob Data Contributor | Subscription dello storage esistente | Carica i CSV usando `--auth-mode login`; Contributor da solo non concede i permessi dati Blob. |
| Reader | Subscription primarie e DR, per chi esegue la verifica delle risorse | Permette l'inventario e il controllo del risultato, senza autorizzare il reset dei cloni. |

Chi predispone le assegnazioni usa Role Based Access Control Administrator, User Access Administrator o Owner negli scope interessati, secondo la governance aziendale. Questo privilegio amministrativo non e richiesto alla Function e non e necessario all'operatore del deployment quando tutti i ruoli sono gia assegnati. Il reset dei cloni DR e un'attivita distinta: richiede autorizzazione esplicita e permessi di gestione compute/rete nella subscription DR, senza eliminare Resource Group o prerequisiti.

## Quali prerequisiti tecnici verificare

1. Nelle subscription interessate registrare i resource provider `Microsoft.Web`, `Microsoft.App`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.ManagedIdentity`, `Microsoft.Insights` e `Microsoft.OperationalInsights` per l'hosting; `Microsoft.Compute`, `Microsoft.Network` e `Microsoft.KeyVault` per i workload DR. Un resource provider e il servizio Azure che gestisce quei tipi di risorse. Verificare disponibilita regionale di Flex Consumption/PowerShell 7.6 e quota compute per le VM DR.
2. Storage, Function, VNet e Private Endpoint devono rispettare le policy applicabili. Lo storage deve supportare Blob/Queue/Table, TLS 1.2 e autenticazione Microsoft Entra; non occorrono Azure Files o storage key. Mantenere disabilitati accesso pubblico, accesso anonimo ai blob e shared key. Le impostazioni dell'account esistente restano responsabilita del suo gestore.
3. La postazione deve raggiungere gli indirizzi privati di Function, del suo nome `scm` usato per pubblicare il codice, e dello storage. Deve risolvere quei nomi mediante le zone DNS create, avere connettivita alla VNet ed uscita HTTPS autorizzata per autenticazione Azure, Azure Resource Manager, registry Terraform e PowerShell Gallery. Il codice della Function chiama anche il management endpoint Azure; ingress privato non significa assenza di ogni uscita pubblica. Non e necessario peering al primario per leggere VM e dischi tramite il management endpoint.
4. Tutte le risorse DR devono essere predisposte nella regione del DES: gruppi workload, VNet/subnet, ASG, Load Balancer/backend pool, Network Security Group (NSG), cioe regole di traffico delle subnet/NIC, e cifratura. I nomi devono rispettare `target_name_suffix`; i riferimenti devono essere leggibili dall'identita corretta. La subnet DR deve contenere gli IP sorgenti che il codice riutilizza, senza conflitti; nessun IP della bolla deve essere gia occupato da altre risorse.
5. Il Key Vault DR deve avere soft delete e purge protection, cioe recupero delle eliminazioni e protezione dalla cancellazione definitiva, con chiave abilitata/non scaduta. L'identita del DES, distinta dalle due UAMI della Function, deve avere Key Vault Crypto Service Encryption User sulla subscription del vault quando si usa RBAC, oppure le autorizzazioni `get`, `wrapKey`, `unwrapKey` sulla chiave se si usano access policy. Il DES deve poter raggiungere il vault secondo la configurazione supportata, compreso il trusted-services bypass richiesto quando il firewall lo limita. Questi permessi non si assegnano a UAMI2 per sostituire l'identita del DES.
6. Verificare dischi gestiti, DES del disco OS, tag/nome delle risorse, disponibilita dello SKU VM (Stock Keeping Unit, cioe il modello e dimensionamento Azure), compatibilita della generazione VM e del disk controller, presenza della NIC/IP configuration primaria e spazio IP nelle subnet DR. La copia snapshot di dischi cifrati deve essere provata con le stesse identita e policy effettive prima di un'attivazione operativa.
7. Sulla postazione installare Git, Terraform 1.9 o successivo, Azure CLI e PowerShell 7.6. La configurazione verificata usa il provider AzureRM del file di lock e i moduli indicati in `function-app/requirements.psd1`; non aggiornarli implicitamente durante il deployment. La build scarica e include i moduli, non dipende da un download automatico al cold start.

Le assegnazioni RBAC devono essere effettive prima del test; una scrittura riuscita dell'assegnazione non prova che il runtime sia gia autorizzato. Verificare una richiesta reale e non aggirare la propagazione modificando firewall o scegliendo un'altra identita. Per il deployment e i primi controlli, seguire i comandi sotto; la prima POST valida modifica risorse DR e deve essere autorizzata dal gestore della bolla.

## Che cosa crea Terraform e che cosa conserva

Terraform legge Resource Group, Storage Account e UAMI esistenti. Crea piano Linux Flex Consumption, Function App privata, VNet, subnet di integrazione, subnet per Private Endpoint, container `app-package`, `dr-configs`, `dr-logs`, Log Analytics workspace e Application Insights con diagnostica.

Un Private Endpoint e un indirizzo privato per raggiungere un servizio. Sono previsti un endpoint della Function e tre endpoint storage per Blob, Queue e Table, con zone DNS private e collegamenti alla VNet. La VNet Integration riguarda l'uscita dalla Function; il suo Private Endpoint riguarda l'ingresso. L'accesso pubblico della Function e disabilitato.

La subnet di integrazione usa una delega `Microsoft.App/environments` ed e almeno /27 per questa singola app. Gli indirizzi devono essere scelti senza sovrapposizioni con le reti esistenti. I default sono esempi, non indirizzi gia riservati al proprio ambiente. Terraform non altera firewall, identita o account storage esistenti per aggirare un errore.

## Come configurare e creare il nuovo hosting

Usare Terraform 1.9 o successivo, Azure CLI (`az`), PowerShell 7.6 e una postazione con il percorso privato necessario. L'operatore deve poter creare le nuove risorse, collegare le identita, creare i container e diagnostic settings e pubblicare il codice. Per caricare CSV serve anche il ruolo dati Blob appropriato; i permessi dell'operatore sono distinti dai ruoli delle UAMI.

1. Scaricare il progetto e aprire PowerShell nella sua cartella.

   ```powershell
   git clone https://github.com/lupass93/attivazione-dr-bolla.git
   Set-Location attivazione-dr-bolla
   Copy-Item ./terraform/terraform.tfvars.example ./terraform/terraform.tfvars
   ```

   Il clone scarica il codice. La copia prepara il file locale con i valori dell'ambiente; non modificarli dentro `main.tf`.

2. Compilare `terraform/terraform.tfvars` con subscription, nomi delle risorse esistenti, identita, nome univoco della Function e indirizzi di rete. `variables.tf` descrive ogni input. Se storage o UAMI sono in altri Resource Group, compilare anche i rispettivi input facoltativi. Non usare i valori fittizi dell'esempio per il deployment.

3. Autenticarsi, inizializzare e validare Terraform.

   ```powershell
   az login
   terraform -chdir=terraform init
   terraform -chdir=terraform validate
   terraform -chdir=terraform plan -out=deployment.tfplan
   ```

   Il login autentica l'operatore. `init` prepara il provider nella versione del file di lock; `validate` verifica la configurazione. `plan` mostra le operazioni e salva il piano. Verificare che non proponga sostituzione o cancellazione delle risorse preesistenti. I piani e lo stato possono contenere informazioni sensibili e non vanno pubblicati.

4. Applicare solo il piano esaminato.

   ```powershell
   terraform -chdir=terraform apply deployment.tfplan
   terraform -chdir=terraform output
   ```

   `apply` crea le risorse nuove e puo generare costi. Gli output mostrano i riferimenti operativi, non le function key. Un secondo `terraform plan` deve risultare senza modifiche inattese.

## Come creare il pacchetto e pubblicare il codice

```powershell
./scripts/build.ps1
./scripts/deploy.ps1
```

`build.ps1` scarica solo i moduli Azure mancanti nelle versioni fissate in `function-app/requirements.psd1`, elimina versioni aggiuntive nella cartella generata per evitare conflitti nei runspace e crea `out/function-app.zip` dopo la verifica sintattica. Il pacchetto ha `host.json` alla radice, permessi leggibili dal worker Linux e non contiene `local.settings.json`. Moduli e ZIP generati restano locali e sono ignorati da Git. Per una build con moduli gia disponibili si puo usare `-SkipModuleDownload`.

`deploy.ps1` legge destinazione e URL dagli output Terraform, seleziona host storage identity-based rimuovendo l'eventuale impostazione legacy `AzureWebJobsStorage`, pubblica lo ZIP e verifica entrambe le API con richieste prive di CSV. L'esito atteso e HTTP 400 per entrambe: dimostra che rispondono, senza avviare la replica. Il deploy richiede accesso al nome privato della Function e del suo servizio di pubblicazione. Non viene aperto l'accesso pubblico.

Non usare `WEBSITE_RUN_FROM_PACKAGE`, storage key o un account diverso per superare errori su Flex Consumption. Non pubblicare durante una replica: una pubblicazione puo riavviare il processo. Conservare l'ultimo pacchetto verificato per ripubblicarlo, se necessario; questa operazione non ripristina le risorse DR.

## Come preparare il CSV delle VM sorgenti

Comma-Separated Values (CSV) indica un file di righe e colonne separate da virgole. Copiare `examples/vms.csv` in un file locale e sostituire subscription, Resource Group e nome VM con i riferimenti reali. `SourceSubscription` puo essere l'ID o il nome della subscription primaria. La subscription DR viene invece scelta dall'input Terraform `dr_subscription_id`.

I gruppi e i nomi dei prerequisiti DR vengono derivati dai nomi sorgenti con `target_name_suffix`, che per default vale `-DR`. VM e dischi mantengono il nome sorgente, NIC e snapshot seguono i nomi del codice. La regione della replica e quella del DES DR, non necessariamente la regione dell'hosting. Verificare questa convenzione prima della POST.

Da PowerShell preparare i riferimenti del nuovo hosting:

```powershell
$Outputs = terraform -chdir=terraform output -json | ConvertFrom-Json
$Subscription = $Outputs.hosting_subscription_id.value
$ResourceGroup = $Outputs.resource_group_name.value
$FunctionName = $Outputs.function_app_name.value
$ApiUrl = $Outputs.api_url.value
$StorageAccount = $Outputs.storage_account_name.value
```

Queste righe leggono i valori creati da Terraform. Non stampano credenziali e non avviano la bolla.

Caricare il file locale sullo storage privato, ad esempio:

```powershell
az storage blob upload --account-name $StorageAccount --container-name dr-configs --name configurations/my-vms.csv --file ./my-vms.csv --auth-mode login --overwrite
$CsvBlobPath = 'configurations/my-vms.csv'
```

Il comando autentica l'operatore con Azure CLI e carica il CSV nel container `dr-configs`. Sovrascrive quel blob se esiste. La variabile conserva il percorso remoto, non il contenuto del file. Non pubblicare il CSV reale nel repository.

## Come attivare la bolla con Invoke-DRReplication

Application Programming Interface (API) indica l'interfaccia HTTP della Function. La function key e il segreto condiviso che Azure custodisce per autorizzare le chiamate; resta valido finche viene ruotato o revocato. Recuperarlo in memoria e non inserirlo nell'URL o negli screenshot:

```powershell
$FunctionKey = az functionapp keys list --subscription $Subscription --resource-group $ResourceGroup --name $FunctionName --query functionKeys.default -o tsv
$Headers = @{ 'x-functions-key' = $FunctionKey }
$RequestBody = @{ csvBlobPath = $CsvBlobPath } | ConvertTo-Json
$Activation = Invoke-RestMethod -Method Post -Uri "$ApiUrl/Invoke-DRReplication" -Headers $Headers -ContentType 'application/json' -Body $RequestBody -TimeoutSec 300 -StatusCodeVariable ActivationCode
$ActivationCode
$Activation | Format-List invocationId, vmCount, startedAt, message
```

`ConvertTo-Json` genera il formato strutturato della richiesta senza escape manuali. La POST scarica il CSV e crea o riusa snapshot, dischi, NIC, VM e associazioni ai pool. La risposta ordinaria e HTTP 202 con il nuovo `invocationId`, identificatore di quella esecuzione condiviso da tutte le sue VM. Una nuova POST genera un nuovo ID anche con lo stesso CSV.

**Il 202 arriva a fine elaborazione nel codice attuale e non certifica il successo di tutte le VM.** Il frontend Azure puo perdere la risposta oltre circa 230 secondi, anche con timeout locale 300 e `functionTimeout=-1`, che elimina il limite di esecuzione. Non rilanciare automaticamente dopo un timeout: il processo puo essere ancora attivo. Usare inizialmente CSV piccoli e invocazioni sequenziali; `vmParallelThrottle` deve essere 1 nella configurazione con due identita.

## Come leggere lo stato con Get-DRStatus

```powershell
$StatusUrl = "$ApiUrl/Get-DRStatus?csvBlobPath=$CsvBlobPath"
$Status = Invoke-RestMethod -Method Get -Uri $StatusUrl -Headers $Headers
$Status.summary | Format-List
$Status.results | Format-Table vmName, status, invocationId, lastCompletedStage, failedStage
```

La GET legge il CSV e i log, senza creare risorse. `summary` conta successi, fallimenti, lavorazioni aperte, stati sconosciuti ed errori di lettura. `results` mostra l'esito per VM. Ripetere la GET per aggiornare; non ripetere la POST.

| Quale stato compare | Quale evidenza considera il codice |
|---|---|
| SUCCEEDED | Esiste il log finale di successo per l'esecuzione selezionata. |
| FAILED | Esiste un log dello stage fallito. Le risorse parziali non sono eliminate automaticamente. |
| IN_PROGRESS | Ci sono log senza marker finale; non prova che il processo sia ancora attivo dopo un'interruzione. |
| UNKNOWN | Non ci sono log riconoscibili. |
| ERROR | La lettura dei log di quella VM ha incontrato un errore. |

**Oggi l'API sceglie separatamente per ogni VM l'esecuzione con il log modificato piu recentemente. Non implementa un filtro per invocationId o activationId.** Prima di dichiarare successo, confrontare ogni ID con `$Activation.invocationId`: scritture tardive o assenza di nuovi log possono far comparire risultati di prove precedenti. Il reset dei cloni non cancella i log. Controllare in Azure che VM, dischi e NIC esistano e siano operativi; i log non certificano la salute delle applicazioni.

## Quali limiti restano importanti

- Snapshot di dischi diversi non coordinano le scritture delle applicazioni. Il codice non fornisce una replica continua o una garanzia di consistenza applicativa.
- Il riuso degli snapshot non verifica la loro eta; una nuova chiamata puo riusare dati precedenti.
- Il riuso delle VM confronta alcune proprieta, non tutta la configurazione o la salute. Non avviare esecuzioni concorrenti sugli stessi nomi.
- La VM DR viene creata senza zona esplicita; i dischi conservano le zone sorgenti quando supportato. Non e garantita la distribuzione zonale delle VM.
- L'assenza di un ASG DR produce un warning: i prerequisiti devono essere verificati prima della replica.
- Non esiste un'API di smantellamento. La rimozione dei cloni e una procedura amministrativa separata e autorizzata; conservare i prerequisiti. VM, dischi, snapshot e monitoring generano costi finche restano utilizzati o conservati.

## Come interpretare gli errori

| Quale risposta compare | Che cosa controllare |
|---|---|
| HTTP 400 | Percorso CSV assente, righe non valide oppure parallelismo non ammesso. |
| HTTP 401 | Function key assente o errata. |
| HTTP 403 o endpoint irraggiungibile | Autorizzazione o percorso privato/DNS; non aprire il servizio pubblico per aggirarlo. |
| HTTP 404 | Il blob CSV non esiste nel container configurato. |
| HTTP 500 | Consultare i log della Function; l'errore pubblico non espone l'eccezione interna. |
| FAILED con AuthorizationFailed | Identita e ruolo effettivi sull'operazione indicata, compresi i riferimenti al disco sorgente. |

## Cosa ho dato per scontato

Il gestore dell'ambiente fornisce risorse preesistenti, ruoli sufficienti, cifratura DR e percorso privato funzionante. Sono prerequisiti da verificare, non garantiti dal Terraform o dal README.

## Le 3 domande che ti verrebbe da farmi

1. Devo modificare il codice per un nuovo ambiente? No: configurare tfvars e CSV; leggere i prerequisiti e la convenzione dei nomi.
2. Posso dichiarare la bolla sana con HTTP 202? No: controllare ID, stati e risorse; per le applicazioni servono test applicativi.
3. Posso riprovare subito dopo un timeout? No: verificare prima che la precedente esecuzione non sia ancora attiva.

## Fonti

- Provider e risorsa Flex: https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/function_app_flex_consumption
- Variabili Terraform: https://developer.hashicorp.com/terraform/language/values/variables
- Networking privato e subnet: https://learn.microsoft.com/azure/azure-functions/functions-networking-options
- Packaging e deployment Flex: https://learn.microsoft.com/azure/azure-functions/deployment-zip-push?pivots=flex-consumption-plan
- PowerShell, moduli e contesti: https://learn.microsoft.com/azure/azure-functions/functions-reference-powershell
- Selezione UAMI: https://learn.microsoft.com/powershell/module/az.accounts/connect-azaccount
- Permessi di lettura ed export dei dischi: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/compute#disk-backup-reader
- Ruoli compute e snapshot: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/compute
- Ruoli dati storage: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/storage
- Ruoli di gestione e identita: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/identity
- Invio telemetria autenticata: https://learn.microsoft.com/azure/azure-monitor/app/azure-ad-authentication
- Cifratura tramite Disk Encryption Set: https://learn.microsoft.com/azure/virtual-machines/disks-enable-customer-managed-keys-portal
- Ruoli di rete: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/networking
- Assegnazione dei ruoli e scope: https://learn.microsoft.com/azure/role-based-access-control/role-assignments-portal
- Timeout: https://learn.microsoft.com/azure/azure-functions/functions-scale#function-app-timeout-duration
- Comportamento della replica e dello stato: codice in `function-app/Invoke-DRReplication`, `Get-DRStatus` e `Modules/DRCore`. Le fonti Microsoft supportano le funzionalita della piattaforma, non certificano automaticamente questa implementazione.
# Guida per condurre il test cliente della versione con criticita e acronimo

**Aggiornata il 17 novembre 2026.** La guida descrive `feature/multiple-lb_logging-actions-and-info-check-rg`: mantiene CSV e report cliente e aggiunge piu Load Balancer, gruppi di networking distinti e cronologia delle operazioni. I collaudi storici del 20 ottobre restano identificati come tali. Le nuove funzionalita richiedono il pacchetto aggiornato; una modifica della sola documentazione non richiede deployment.

**Percorso consigliato:** usare una Function gia distribuita e verificata. Non eseguire Terraform o ripubblicare il codice durante la dimostrazione se l'ambiente e gia pronto. La sezione finale sul deployment serve soltanto per una prima installazione o un aggiornamento autorizzato.

Il [README](../README.md) rimane il riferimento del contratto e dei limiti. Questa guida e la procedura operativa: spiega quali comandi eseguire e quale risultato osservare.

## Quale risultato deve ottenere il cliente

Il test dimostra che il cliente puo caricare un elenco di Virtual Machine (VM), server virtuali Azure, attivare la replica nel Disaster Recovery (DR), l'ambiente di ripristino, e seguirne l'esito per sessione e criticita.

Le Application Programming Interface (API) sono le interfacce chiamate dal client. Usano Hypertext Transfer Protocol (HTTP); HTTPS protegge il trasporto con cifratura. La Function App ospita tre funzioni:

| Quale funzione utilizza il test | Come viene utilizzata |
|---|---|
| `Invoke-DRReplication`. | Il client esegue una POST; la funzione valida CSV/richiesta, registra la sessione e accoda. |
| `Process-DRSession`. | La Queue attiva automaticamente il worker, la funzione che esegue preflight e replica. **Non esiste una chiamata HTTP da eseguire manualmente a questo componente.** |
| `Get-DRStatus`. | Il client esegue GET o POST passando la sessione; la funzione legge lo stato persistente. |

Azure Queue Storage conserva il messaggio da elaborare. Azure Blob Storage conserva richiesta, stato e log. Il `sessionId` e un Universally Unique Identifier (UUID), identificativo generato dal client prima della POST e conservato per ritrovare l'attivazione. Non e una credenziale.

**Criterio di successo:** la richiesta valida viene accettata, il worker esegue il lavoro, la sessione termina correttamente, ordine/log/risorse sono coerenti e l'applicazione viene verificata separatamente. HTTP 202 da solo non basta.

## Prima della riunione: confermare scope e prerequisiti

### Scegliere se provare una creazione nuova oppure il riuso

- **Creazione nuova:** il responsabile DR conferma una destinazione di test priva di VM, NIC e dischi replicati. Una Network Interface (NIC) e la scheda di rete Azure della VM. Questo percorso permette di verificare nuovi timestamp di creazione e nuove copie.
- **Riuso:** le risorse esistono gia; il test verifica il loro riuso, non un nuovo punto di ripristino o nuovi timestamp. I dischi non vengono aggiornati dal primario.
- **VM esistenti ma spente:** il codice non le avvia automaticamente. Il responsabile puo avviarle prima della prova, se autorizzato. Non presentare il riuso di una VM spenta come una nuova accensione eseguita dalla Function.

**Non cancellare risorse o modificare suffissi di destinazione durante la riunione per improvvisare un test da zero.** Preparare prima una destinazione autorizzata. Non avviare sessioni sovrapposte sugli stessi workload.

### Verificare rete, autorizzazioni e prerequisiti DR

Un Private Endpoint collega un servizio a un indirizzo privato della rete Azure. Il Domain Name System (DNS) deve risolvere Function e storage nei rispettivi indirizzi privati. Il login Azure, da solo, non fornisce tale connettivita.

| Quale soggetto deve essere pronto | Quali condizioni verificare |
|---|---|
| Postazione del cliente. | PowerShell 7.6, Git e Azure CLI per i passi API di questa guida; accesso privato a Function e Blob. Il deploy puo usare PowerShell o Bash con target esplicito, senza Terraform; quest'ultimo serve solo scegliendo la modalita basata sui suoi output. Non assumere che una Cloud Shell pubblica raggiunga i servizi privati. |
| Operatore delle API. | Function key fornita dal responsabile oppure permesso per leggerla; upload sul container CSV e lettura di log/sessioni. La function key e un segreto condiviso valido fino alla rotazione, non il `sessionId`. |
| Operatore che verifica le risorse. | Lettura dei gruppi/subscription sorgenti e DR. I ruoli delle identita della Function non vengono automaticamente attribuiti alla persona. |
| UAMI sorgente/storage. | Una User-Assigned Managed Identity (UAMI) e un'identita Azure gestita senza password. Questa identita legge il primario e ha Storage Blob Data Owner, Storage Queue Data Contributor e Storage Table Data Contributor sullo storage; invia telemetria con Monitoring Metrics Publisher. |
| UAMI DR. | Contributor sui gruppi workload DR, permessi di rete/cifratura necessari e Disk Backup Reader sui dischi/gruppi primari. Il solo Reader dell'altra identita non basta alla copia. |
| Prerequisiti DR. | Gruppi distinti di VM, NIC e networking; rete/subnet, Application Security Group (ASG), che raggruppano le NIC, Network Security Group (NSG), che filtra il traffico, e Disk Encryption Set (DES), che seleziona la chiave dei dischi, esistenti. Devono esistere tutti i Load Balancer e i backend pool richiesti dalle configurazioni IP della NIC primaria. |
| Cifratura e regione. | Chiave e identita DES autorizzate; source e target nello stesso tenant Microsoft Entra e dischi nella stessa regione. La copia diretta non realizza DR geografico. |

Per upload bastano i permessi dati necessari sul container CSV; per leggere log/sessioni servono i relativi permessi dati di lettura. Il ruolo Contributor sulla Function non concede automaticamente accesso ai contenuti Blob. Non assegnare ruoli piu ampi soltanto per velocizzare il test: seguire la [matrice completa](../README.md#quali-autorizzazioni-e-prerequisiti-verificare).

I passi 2-5 sono la preparazione del responsabile tecnico con i permessi di gestione indicati. Un consumatore delle sole API non deve ricevere quei privilegi: il responsabile prepara i riferimenti e fornisce la key tramite il canale approvato; il client usa i passi operativi successivi. L'accesso diretto alla Queue non e necessario per invocare le API.

## Passo 1. Aprire il codice della versione corretta

Usare una directory nuova, senza sovrascrivere un checkout esistente:

Il repository e privato: l'account GitHub del cliente deve avere accesso ed essere autenticato nel client Git secondo la procedura aziendale. `az login` autentica Azure, non GitHub. Non inserire token nell'URL e non copiare credenziali sulla postazione di test; in alternativa il responsabile consegna codice/pacchetto verificati con un canale approvato.

```powershell
git clone --branch feature/multiple-lb_logging-actions-and-info-check-rg --single-branch https://github.com/lupass93/attivazione-dr-bolla.git attivazione-dr-bolla-test-cliente
if ($LASTEXITCODE -ne 0) { throw 'Clone non riuscito.' }
Set-Location attivazione-dr-bolla-test-cliente
git branch --show-current
git rev-parse HEAD
$PSVersionTable.PSVersion
$ErrorActionPreference = 'Stop'
```

**Atteso:** ramo `feature/multiple-lb_logging-actions-and-info-check-rg` e PowerShell 7.6. Registrare la versione effettivamente usata. Eseguire i passi successivi **nella stessa finestra PowerShell**, cosi le variabili restano disponibili.

Il ramo CSV/log precedente resta una consegna storica; per queste integrazioni usare il ramo indicato sopra, senza merge in delivery.

## Passo 2. Selezionare il tenant e la Function concordati

Sostituire i quattro valori con quelli dell'ambiente cliente, non con nomi fittizi:

```powershell
$ExpectedTenantId = 'INSERIRE-TENANT-ID'
$HostingSubscription = 'INSERIRE-SUBSCRIPTION-HOSTING'
$HostingResourceGroup = 'INSERIRE-RESOURCE-GROUP-HOSTING'
$FunctionName = 'INSERIRE-NOME-FUNCTION-APP'
if (@($ExpectedTenantId, $HostingSubscription, $HostingResourceGroup, $FunctionName) -match '^INSERIRE-') {
    throw 'Compilare prima i parametri dell ambiente concordato.'
}
az login --tenant $ExpectedTenantId
if ($LASTEXITCODE -ne 0) { throw 'Login Azure non riuscito.' }
az account set --subscription $HostingSubscription
if ($LASTEXITCODE -ne 0) { throw 'Subscription non selezionabile.' }
$Account = az account show -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $Account.tenantId -ne $ExpectedTenantId) {
    throw 'Il tenant attivo non coincide con quello concordato.'
}
$Account | Select-Object name, id, tenantId
```

Se l'identita e gia connessa correttamente, non serve ripetere il login. I nomi e identificativi non confermati sono un punto di arresto, non un motivo per scegliere una subscription a tentativi.

## Passo 3. Leggere gli indirizzi e i container effettivamente distribuiti

Questa lettura non richiede di avere sul computer lo stato Terraform del deployment:

```powershell
$SiteUri = "https://management.azure.com/subscriptions/$HostingSubscription/resourceGroups/$HostingResourceGroup/providers/Microsoft.Web/sites/${FunctionName}?api-version=2024-04-01"
$Site = az rest --method get --url $SiteUri -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Impossibile leggere la Function concordata.' }
if ($Site.properties.publicNetworkAccess -ne 'Disabled') {
    throw 'La Function non risulta configurata con accesso pubblico disabilitato.'
}
$ApiUrl = "https://$($Site.properties.defaultHostName)/api"
$SettingQuery = "[?name=='CSV_STORAGE_CONNECTION__blobServiceUri' || name=='CSV_CONTAINER_NAME' || name=='LOG_CONTAINER_NAME' || name=='SESSION_CONTAINER_NAME' || name=='DR_QUEUE_NAME' || name=='DR_QUEUE_CONNECTION__queueServiceUri' || name=='DR_STORAGE_RESOURCE_ID']"
$Settings = az functionapp config appsettings list --subscription $HostingSubscription `
    --resource-group $HostingResourceGroup --name $FunctionName --query $SettingQuery -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Impossibile leggere le impostazioni operative.' }
$Map = @{}
foreach ($Setting in $Settings) { $Map[$Setting.name] = $Setting.value }
foreach ($Required in @('CSV_STORAGE_CONNECTION__blobServiceUri', 'CSV_CONTAINER_NAME', 'LOG_CONTAINER_NAME',
        'SESSION_CONTAINER_NAME', 'DR_QUEUE_NAME', 'DR_QUEUE_CONNECTION__queueServiceUri')) {
    if ([string]::IsNullOrWhiteSpace([string]$Map[$Required])) { throw "Impostazione mancante: $Required" }
}
$BlobServiceUri = $Map['CSV_STORAGE_CONNECTION__blobServiceUri']
$QueueServiceUri = $Map['DR_QUEUE_CONNECTION__queueServiceUri']
$StorageAccount = ([uri]$BlobServiceUri).DnsSafeHost.Split('.')[0]
$CsvContainer = $Map['CSV_CONTAINER_NAME']
$LogContainer = $Map['LOG_CONTAINER_NAME']
$SessionContainer = $Map['SESSION_CONTAINER_NAME']
$QueueName = $Map['DR_QUEUE_NAME']
[pscustomobject]@{
    ApiUrl = $ApiUrl; StorageAccount = $StorageAccount
    CsvContainer = $CsvContainer; LogContainer = $LogContainer
    SessionContainer = $SessionContainer; QueueName = $QueueName
}
```

**Atteso:** parametri dell'ambiente concordato. Questa operazione richiede permessi di gestione per leggere configurazione e chiavi; se il cliente non li ha, il responsabile fornisce questi valori e la key tramite il canale approvato. Non mostrare o esportare l'intero elenco delle impostazioni.

`DR_STORAGE_RESOURCE_ID` deve indicare l'identificativo completo dello Storage Account per includerne il vero Resource Group nella cronologia Data Plane. Terraform lo configura automaticamente; negli altri ambienti lo imposta il responsabile. L'assenza non viene sostituita da un gruppo presunto.

Se si dispone gia dello stato Terraform corretto, gli stessi riferimenti sono negli output di `terraform -chdir=terraform output -json`. Un clone nuovo non contiene quello stato: il solo clone non rende disponibili gli output.

## Passo 4. Verificare la risoluzione privata dalla postazione

```powershell
foreach ($Endpoint in @($ApiUrl, $BlobServiceUri)) {
    $HostName = ([uri]$Endpoint).DnsSafeHost
    $Addresses = @([System.Net.Dns]::GetHostAddresses($HostName))
    if ($Addresses.Count -eq 0) { throw "Nessun indirizzo per $HostName" }
    foreach ($Address in $Addresses) {
        $Bytes = $Address.GetAddressBytes()
        $Private = $Bytes.Length -eq 4 -and (
            $Bytes[0] -eq 10 -or
            ($Bytes[0] -eq 172 -and $Bytes[1] -ge 16 -and $Bytes[1] -le 31) -or
            ($Bytes[0] -eq 192 -and $Bytes[1] -eq 168))
        if (-not $Private) { throw "Risoluzione non privata per $HostName. Fermare il test." }
        [pscustomobject]@{ Servizio = $HostName; IndirizzoPrivato = $Address.IPAddressToString }
    }
}
```

**Atteso dalla postazione:** Function e Blob risolvono soltanto in indirizzi IPv4 privati. Una risoluzione corretta non prova da sola raggiungibilita o autorizzazioni: i passi HTTP e Blob successivi completano il controllo. Non aprire l'accesso pubblico per superare un errore.

Queue e Table devono essere raggiungibili privatamente dal runtime della Function. Il normale client non li chiama direttamente: la risoluzione Queue della postazione non e una condizione necessaria alle API. Il responsabile verifica i relativi Private Endpoint e la rete della Function; l'elaborazione reale della sessione ne conferma il funzionamento.

## Passo 5. Verificare le tre funzioni e custodire la key

```powershell
$Functions = @(az functionapp function list --subscription $HostingSubscription `
    --resource-group $HostingResourceGroup --name $FunctionName --query '[].name' -o tsv)
if ($LASTEXITCODE -ne 0) { throw 'Elenco funzioni non disponibile.' }
foreach ($ExpectedFunction in @('Invoke-DRReplication', 'Process-DRSession', 'Get-DRStatus')) {
    if (-not ($Functions -match "/$ExpectedFunction$")) { throw "Funzione non indicizzata: $ExpectedFunction" }
}
$Functions
$FunctionKey = az functionapp keys list --subscription $HostingSubscription `
    --resource-group $HostingResourceGroup --name $FunctionName --query functionKeys.default -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($FunctionKey)) { throw 'Function key non disponibile.' }
$Headers = @{ 'x-functions-key' = $FunctionKey }
```

La key resta in memoria e viene inviata nell'header, il campo della richiesta `x-functions-key`. Non stamparla, non metterla nell'URL, nel CSV, nei file di sessione o nelle schermate della riunione. L'indicizzazione non dimostra da sola che il worker abbia elaborato un messaggio: lo si verifica con la sessione reale.

## Passo 6. Provare gli endpoint senza avviare risorse

```powershell
$Probe = Invoke-RestMethod -Method Post -Uri "$ApiUrl/Invoke-DRReplication" -Headers $Headers `
    -ContentType 'application/json' -Body '{}' -SkipHttpErrorCheck -StatusCodeVariable ProbeCode -TimeoutSec 60
if ($ProbeCode -ne 400) { throw "Invoke senza sessionId: atteso 400, ricevuto $ProbeCode" }
$Probe = Invoke-RestMethod -Method Get -Uri "$ApiUrl/Get-DRStatus" -Headers $Headers `
    -SkipHttpErrorCheck -StatusCodeVariable ProbeCode -TimeoutSec 60
if ($ProbeCode -ne 400) { throw "Stato senza sessionId: atteso 400, ricevuto $ProbeCode" }
$ProbeId = [guid]::NewGuid().ToString('D')
$Probe = Invoke-RestMethod -Method Get -Uri "$ApiUrl/Get-DRStatus?sessionId=$ProbeId" `
    -SkipHttpErrorCheck -StatusCodeVariable ProbeCode -TimeoutSec 60
if ($ProbeCode -ne 401) { throw "Stato senza key: atteso 401, ricevuto $ProbeCode" }
```

**Atteso:** 400, 400 e 401. Queste richieste non avviano replica. Un 503 e un errore da diagnosticare o ritentare in modo limitato, non un risultato da contare come PASS.

## Passo 7. Preparare il CSV e mostrare l'ordine atteso

Copiare il modello e sostituire i valori fittizi con quattro VM approvate, una per classe. Per dimostrare il riordino lasciare le righe in ordine inverso:

```powershell
Copy-Item ./examples/vms-priorities.csv ./my-vms.csv
$CsvFile = (Resolve-Path ./my-vms.csv).Path
```

Prima di proseguire, modificare `my-vms.csv` con il normale editor. L'intestazione standard e:

```csv
Criticita,Acronimo,SourceSubscription,SourceResourceGroup,SourceVmName
```

Le nove etichette accettate sono nella [tabella del contratto](../README.md#quale-ordine-di-attivazione-applica-il-worker). Gli acronimi sono identificativi applicativi; piu VM possono condividere lo stesso valore. Non importare le altre colonne GCP.

Un'anteprima locale riusa la stessa normalizzazione della Function, senza collegarsi ad Azure:

```powershell
Import-Module ./function-app/Modules/DRSessions/DRSessions.psm1 -Force
$CsvRows = @(Import-Csv -LiteralPath $CsvFile)
if ($CsvRows.Count -eq 0) { throw 'CSV senza righe dati.' }
$Preview = @(for ($Index = 0; $Index -lt $CsvRows.Count; $Index++) {
    $Row = $CsvRows[$Index]
    if ([string]::IsNullOrWhiteSpace($Row.Acronimo)) { throw "Acronimo mancante alla riga dati $($Index + 1)." }
    $Class = Resolve-DRCriticality $Row.Criticita
    [pscustomobject]@{
        RigaOriginale = $Index + 1; Priorita = $Class.Priority; Classe = $Class.Class
        Acronimo = $Row.Acronimo; VM = $Row.SourceVmName
    }
})
$Preview | Sort-Object Priorita, RigaOriginale -Stable | Format-Table -AutoSize
```

**Atteso:** sistemico -> altamente critico -> critico -> non critico; parita nell'ordine originale. Questa e un'anteprima, non sostituisce la validazione completa del server. Il modello usa nomi di colonna standard; se si copia l'header con apostrofi dal riferimento cliente, convertirlo nel formato standard per questa anteprima.

## Passo 8. Generare e salvare la sessione prima della POST

```powershell
$SessionId = [guid]::NewGuid().ToString('D')
$RunDirectory = Join-Path (Get-Location) "out/customer-test/$SessionId"
New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
$CsvBlobPath = "customer-tests/$SessionId/vms.csv"
$Body = @{ sessionId = $SessionId; csvBlobPath = $CsvBlobPath } | ConvertTo-Json
$Body | Set-Content -LiteralPath (Join-Path $RunDirectory 'request.json') -Encoding utf8
@{
    sessionId = $SessionId; apiUrl = $ApiUrl; csvBlobPath = $CsvBlobPath
    hostingSubscription = $HostingSubscription; hostingResourceGroup = $HostingResourceGroup
    functionName = $FunctionName; storageAccount = $StorageAccount
    csvContainer = $CsvContainer; logContainer = $LogContainer; sessionContainer = $SessionContainer
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RunDirectory 'context.json') -Encoding utf8
$SessionId
```

**Atteso:** identificativo noto e file locali senza key. La cartella `out` e esclusa da Git; contiene comunque metadati dell'ambiente e va custodita. Non rieseguire questo passo per ritentare una POST incerta: creerebbe un'altra sessione.

Prima dell'invio, verificare la ricerca di un identificativo non registrato:

```powershell
$Probe = Invoke-RestMethod -Method Get -Uri "$ApiUrl/Get-DRStatus?sessionId=$SessionId" -Headers $Headers `
    -SkipHttpErrorCheck -StatusCodeVariable ProbeCode -TimeoutSec 60
if ($ProbeCode -ne 404) { throw "Sessione nuova: atteso 404 prima della POST, ricevuto $ProbeCode" }
```

## Passo 9. Caricare il CSV nello storage privato

```powershell
az storage blob upload --subscription $HostingSubscription --account-name $StorageAccount `
    --container-name $CsvContainer --name $CsvBlobPath --file $CsvFile `
    --auth-mode login --overwrite --content-type text/csv --output none --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Upload CSV non riuscito; non inviare Invoke.' }
```

L'operatore carica soltanto il file della propria sessione. Non sostituire il percorso con un nome di container predefinito se il deployment usa nomi personalizzati.

## Passo 10. Accettare la richiesta con Invoke

```powershell
$Accepted = Invoke-RestMethod -Method Post -Uri "$ApiUrl/Invoke-DRReplication" -Headers $Headers `
    -ContentType 'application/json' -Body $Body -SkipHttpErrorCheck `
    -StatusCodeVariable InvokeCode -TimeoutSec 120
if ($InvokeCode -ne 202) {
    $Accepted | ConvertTo-Json -Depth 10
    throw "Atteso 202 per una sessione nuova; ricevuto $InvokeCode. Conservare lo stesso sessionId."
}
$Accepted | Format-List sessionId, id, activity, status, queueConfirmed, statusUrl
if ($Accepted.sessionId -ne $SessionId -or -not $Accepted.queueConfirmed) {
    throw 'Accettazione non coerente con la richiesta.'
}
$Accepted | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $RunDirectory 'accepted.json') -Encoding utf8
```

**Messaggio da dare al cliente:** il 202 arriva soltanto dopo conferma della Queue; non significa che la bolla sia pronta. Se una ripetizione della stessa richiesta restituisce 200 con stato terminale, si sta leggendo la sessione gia conclusa, non creando un nuovo workload.

## Passo 11. Osservare il worker e seguire Get-DRStatus con GET

```powershell
$Deadline = [datetime]::UtcNow.AddMinutes(20)
do {
    $Status = Invoke-RestMethod -Method Get -Uri "$ApiUrl/Get-DRStatus?sessionId=$SessionId" -Headers $Headers `
        -SkipHttpErrorCheck -StatusCodeVariable StatusCode -TimeoutSec 60
    if ($StatusCode -ne 200) { throw "Lettura stato: HTTP $StatusCode. Non generare un nuovo ID." }
    if ($Status.sessionId -ne $SessionId) { throw 'Identificativo inatteso nella risposta.' }
    $Status | Select-Object sessionId, status, phase, running
    $Status.results | Format-Table activationOrder, priorityClass, acronimo, vmName, status -AutoSize
    $Status | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $RunDirectory 'status-latest.json') -Encoding utf8
    if ($Status.status -in @('SUCCEEDED', 'FAILED')) { break }
    Start-Sleep -Seconds 5
} while ([datetime]::UtcNow -lt $Deadline)
if ($Status.status -notin @('SUCCEEDED', 'FAILED')) {
    throw 'Monitoraggio terminato per limite locale; il worker non viene annullato. Conservare sessionId e ricontrollare.'
}
```

**Atteso:** QUEUED, poi PREFLIGHT/RUNNING, quindi SUCCEEDED oppure FAILED con errori. Non e necessario osservare tutte le fasi: alcune possono concludersi tra due letture.

`startedAt`, avanzamento delle righe e log mostrano che il queue trigger ha attivato `Process-DRSession`. Non invocarlo dal browser o dal pulsante di test manuale come se fosse un endpoint HTTP.

**Attenzione:** `running` e una stringa per compatibilita con il cliente. Non usare `if ($Status.running)`: anche `"false"` e una stringa non vuota. Per terminare il monitoraggio usare `status`, come sopra; per confrontare il campo usare `$Status.running -eq 'false'`.

## Passo 12. Provare anche Get-DRStatus con POST e leggere il report cliente

```powershell
$StatusPost = Invoke-RestMethod -Method Post -Uri "$ApiUrl/Get-DRStatus" -Headers $Headers `
    -ContentType 'application/json' -Body (@{ sessionId = $SessionId } | ConvertTo-Json) `
    -SkipHttpErrorCheck -StatusCodeVariable StatusPostCode -TimeoutSec 60
if ($StatusPostCode -ne 200 -or $StatusPost.sessionId -ne $SessionId) { throw 'Consultazione POST non riuscita.' }
$ClassSummary = foreach ($ClassName in @('sistemico', 'altamente-critico', 'critico', 'non-critico')) {
    $Group = $StatusPost.$ClassName
    [pscustomobject]@{
        Classe = $ClassName
        Completate = [int]$Group.resource_completed_count
        InAttesa = [int]$Group.resource_pending_count
        Fallite = [int]$Group.resource_error_count
        Totale = [int]$Group.resource_total
    }
}
$ClassSummary | Format-Table -AutoSize
$StatusPost.results | Format-Table activationOrder, csvRow, criticita, acronimo, vmName, startedAt, completedAt -AutoSize
```

Le due forme dell'API leggono la stessa sessione; la POST di stato non avvia replica. Nel JSON originale i contatori rimangono stringhe: la conversione in interi sopra serve soltanto alla tabella locale.

Controllare che completed + pending + error sia uguale al totale di ogni classe. `id` coincide con il `sessionId`, `activity` vale `dr-activation` e le chiavi delle VM includono subscription/gruppo/nome per non confondere omonimi.

## Passo 13. Verificare piano congelato e log del worker

```powershell
$ManifestFile = Join-Path $RunDirectory 'request-stored.json'
$StateFile = Join-Path $RunDirectory 'state-stored.json'
foreach ($Document in @(@{ Name = 'request.json'; File = $ManifestFile }, @{ Name = 'state.json'; File = $StateFile })) {
    az storage blob download --subscription $HostingSubscription --account-name $StorageAccount `
        --container-name $SessionContainer --name "sessions/$SessionId/$($Document.Name)" --file $Document.File `
        --auth-mode login --overwrite --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Download non riuscito: $($Document.Name)" }
}
$Manifest = Get-Content $ManifestFile -Raw | ConvertFrom-Json
$StoredState = Get-Content $StateFile -Raw | ConvertFrom-Json
$Manifest.rows | Format-Table CsvRow, PriorityClass, Acronimo, SourceSubscription, SourceResourceGroup, SourceVmName -AutoSize
$Vm = $StatusPost.results | Where-Object { $_.sourceSubscriptionId } | Select-Object -First 1
if ($null -ne $Vm) {
    $WorkloadPrefix = "$($Vm.sourceSubscriptionId)/$($Vm.sourceResourceGroup)/$($Vm.vmName)/".ToLowerInvariant()
    $LogPrefix = "$WorkloadPrefix$SessionId-"
    $LogNames = @(az storage blob list --subscription $HostingSubscription --account-name $StorageAccount `
        --container-name $LogContainer --prefix $LogPrefix --auth-mode login --query '[].name' -o tsv --only-show-errors)
    if ($LASTEXITCODE -ne 0) { throw 'Elenco log non disponibile.' }
    $LogNames
    $CompletedLog = $LogNames | Where-Object { $_ -like '*-stageCompleted-*' } | Select-Object -First 1
    if ($CompletedLog) {
        $LogFile = Join-Path $RunDirectory 'vm-completion.log'
        az storage blob download --subscription $HostingSubscription --account-name $StorageAccount `
            --container-name $LogContainer --name $CompletedLog --file $LogFile --auth-mode login `
            --overwrite --output none --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Download log non riuscito.' }
        Get-Content $LogFile
    }
}
```

**Atteso:** richiesta congelata nell'ordine di attivazione; stato persistente con gli stessi blocchi cliente; log con `sessionId`, `Criticita` e `Acronimo`. Se il preflight e fallito, cercare i log di fallimento, non pretendere un marker Completed.

La cronologia tecnica e disponibile anche senza log del worker, per esempio dopo un 503 di accodamento:

```powershell
az storage blob list --subscription $HostingSubscription --account-name $StorageAccount `
    --container-name $LogContainer --prefix "sessions/$SessionId/" --auth-mode login `
    --query '[].name' -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Elenco della cronologia operazioni non disponibile.' }
```

I file `Invoke-DRReplication-<runId>.log`, `Process-DRSession-<runId>.log` e `Get-DRStatus-<runId>.log` contengono le azioni Azure, i relativi esiti e la configurazione rilevata. Non sono un nuovo formato del report cliente. Un errore di accodamento resta un 503: leggere il dettaglio tecnico e correggere rete, coda o ruoli prima di ritentare con lo stesso identificativo.

Per diagnosi del processo, in Application Insights interrogare le tracce sostituendo il valore:

```kusto
traces
| where timestamp > ago(2h)
| where message contains "<sessionId-del-test>"
| project timestamp, message
| order by timestamp asc
```

Nel contesto di un Log Analytics workspace la tabella equivalente e `AppTraces`, con colonne `TimeGenerated` e `Message`. Sono necessari i permessi di consultazione; non confondere questi log con il JSON di avanzamento.

## Passo 14. Confermare ordine e risorse direttamente in Azure

```powershell
$ResourceChecks = foreach ($Vm in $StatusPost.results | Where-Object status -eq 'SUCCEEDED') {
    if ([string]::IsNullOrWhiteSpace($Vm.targetSubscriptionId)) { throw 'Subscription DR non risolta.' }
    $TargetGroup = "$($Vm.sourceResourceGroup)$($Manifest.replicationSettings.TargetResourceGroupSuffix)"
    $View = az vm get-instance-view --subscription $Vm.targetSubscriptionId --resource-group $TargetGroup `
        --name $Vm.vmName --query '{states:instanceView.statuses[].code,agent:instanceView.vmAgent.statuses[].displayStatus}' `
        -o json --only-show-errors | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Verifica VM non riuscita: $($Vm.vmName)" }
    $CreatedAt = az vm show --subscription $Vm.targetSubscriptionId --resource-group $TargetGroup `
        --name $Vm.vmName --query timeCreated -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Timestamp VM non disponibile.' }
    [pscustomobject]@{
        Ordine = $Vm.activationOrder; Classe = $Vm.priorityClass; VM = $Vm.vmName
        SubscriptionDR = $Vm.targetSubscriptionId; GruppoDR = $TargetGroup
        StatiAzure = $View.states -join ','; GuestAgent = $View.agent -join ','
        CreataInAzure = $CreatedAt
    }
}
$ResourceChecks | Sort-Object Ordine | Format-Table -AutoSize
```

Una VM appena creata puo avere completato il provisioning prima che il guest agent, il processo interno che comunica con Azure, sia Ready. Attendere e ricontrollare: il collaudo automatico usa un limite di cinque minuti. Verificare anche dischi/cifratura, NIC/IP/ASG/backend pool e il servizio applicativo.

Per le associazioni di rete leggere gli ID NIC direttamente dalla VM DR, senza cercare la NIC nel gruppo della VM. Controllare ogni configurazione IP e tutti i pool, identificando i Load Balancer tramite ID completi: nomi uguali in gruppi diversi non indicano la stessa risorsa. I log di scoperta riportano il mapping dei gruppi sorgenti/DR. Le regole di rete, i frontend e i probe restano esterni alla Function.

**Per una creazione nuova:** le date di creazione devono rispettare il piano sistemico -> altamente critico -> critico -> non critico. In riuso le date sono storiche: usare gli istanti dei tentativi per dimostrare la sequenza e non dichiarare copie nuove.

`SUCCEEDED` certifica le operazioni concluse dal codice, non la salute del database o dell'applicazione. Il test applicativo va eseguito dal relativo responsabile.

## Passo 15. Dimostrare il replay senza creare un altro workload

Ripetere **lo stesso** body e lo stesso identificativo, dopo la conclusione:

```powershell
$Replay = Invoke-RestMethod -Method Post -Uri "$ApiUrl/Invoke-DRReplication" -Headers $Headers `
    -ContentType 'application/json' -Body $Body -SkipHttpErrorCheck -StatusCodeVariable ReplayCode -TimeoutSec 120
if ($ReplayCode -ne 200 -or $Replay.sessionId -ne $SessionId) { throw 'Replay della sessione conclusa non riuscito.' }
$Replay | Select-Object sessionId, status, phase
```

**Atteso:** HTTP 200 e stato gia concluso; nessuna nuova replica. Una sessione FAILED non viene riavviata da questo comando: prima di un nuovo identificativo occorre valutare errori e risorse parziali.

Per provare il controllo 409, usare soltanto un secondo percorso CSV di test approvato con contenuto valido e lo stesso `sessionId`: la richiesta deve essere rifiutata per percorso/contenuto differente. Non modificare il file accettato mentre altre persone lo stanno usando.

## Passo 16. Riprendere dopo timeout, 503 o terminale chiuso

Il file di contesto conserva l'identificativo prima della POST. Riaprire la stessa versione del repository, recuperare parametri e key con i passi 2-5, poi:

```powershell
$RunDirectory = 'INSERIRE-PERCORSO-out/customer-test/UUID'
$Context = Get-Content (Join-Path $RunDirectory 'context.json') -Raw | ConvertFrom-Json
$SessionId = $Context.sessionId
$ApiUrl = $Context.apiUrl
$Body = Get-Content (Join-Path $RunDirectory 'request.json') -Raw
$Recovered = Invoke-RestMethod -Method Get -Uri "$ApiUrl/Get-DRStatus?sessionId=$SessionId" -Headers $Headers `
    -SkipHttpErrorCheck -StatusCodeVariable RecoveredCode -TimeoutSec 60
$RecoveredCode
$Recovered | ConvertTo-Json -Depth 20
```

- **200 e stato non terminale:** continuare a consultare; non generare un altro ID.
- **200 e stato concluso:** leggere l'esito; non serve una nuova POST.
- **404:** la registrazione non e stata trovata. Dopo aver verificato ambiente, percorso e caricamento del CSV, ritentare la stessa richiesta con lo stesso ID.
- **503 o errore di trasporto:** conservare ID/body; ritentare in modo limitato dopo una pausa. Dopo tre tentativi senza esito, coinvolgere il responsabile e consultare log/code. Non contare un 503 come accettazione.
- **FAILED o `requiresReview=true`:** controllare risultati e risorse residue prima di una nuova attivazione; nessun annullamento automatico e stato implementato.

Una scadenza locale del monitoraggio non annulla il worker. Il valore `functionTimeout=-1` non lo rende immune a riavvii o aggiornamenti della piattaforma.

## Passo 17. Chiudere il test e dichiarare l'esito corretto

Registrare versione, ambiente, `sessionId`, CSV, risultato delle API, ordine, contatori, controlli Azure, prova applicativa e risorse residue. Classificare una verifica non eseguita come **non verificata**, non come PASS.

| Quale esito dichiarare | Quali evidenze servono |
|---|---|
| Accettazione riuscita. | Nuova richiesta HTTP 202, sessione corretta e `queueConfirmed=true`. |
| Operazioni della Function riuscite. | Sessione SUCCEEDED, zero errori e zero pending nei quattro blocchi, risorse previste effettivamente presenti. Una sessione FAILED non diventa PASS perche alcune VM sono riuscite. |
| Ordine verificato. | Piano e timestamp dei tentativi coerenti; timestamp di creazione Azure soltanto se le risorse sono nuove. |
| Servizio applicativo disponibile. | Prova specifica dell'applicazione conclusa dal suo responsabile; il solo guest agent Ready non basta. |

Per una prova negativa dei prerequisiti usare esclusivamente una fixture approvata, ad esempio una VM di test che richiede un ASG DR non predisposto. L'esito atteso e FAILED in preflight con dettaglio dell'ASG e nessuna creazione. Non ottenere quel caso cancellando un ASG reale. L'[apposito script](../tests/live-preflight.ps1) e opzionale e richiede scope e accesso privato confermati.

Rimuovere il segreto dalla sessione locale:

```powershell
$Headers.Clear()
Remove-Variable FunctionKey, Headers -ErrorAction SilentlyContinue
```

La Function non espone un'API di smantellamento. Concordare con il responsabile eventuale deallocazione delle sole VM di test e conservazione di dischi/log. Lo storico puo restare SUCCEEDED anche dopo che le VM sono state spente: descrive l'esecuzione, non l'inventario corrente.

## Se serve distribuire o aggiornare il codice prima della prova

Questa e una fase separata e autorizzata, non parte dei test API:

**Usare gli script del repository aggiornato, non l'allegato storico di 37 righe.** [scripts/deploy.ps1](../scripts/deploy.ps1) e [scripts/deploy.sh](../scripts/deploy.sh) ora accettano il target esplicito senza Terraform. La build prepara il ZIP locale; il deploy non scarica il ramo, non esegue la build e non crea infrastruttura.

| Quale situazione presenta il cliente | Quale percorso seguire |
|---|---|
| Hosting asincrono gia pronto, con Queue, sessioni, tre funzioni e ruoli. | Usare il checkout aggiornato CSV/log, confermare subscription hosting/gruppo/nome Function e lanciare build/deploy con questi tre parametri. Terraform non e necessario. |
| Vecchia versione senza infrastruttura asincrona. | Prima piano/apply Terraform autorizzato e ruoli, incluso Storage Queue Data Contributor alla UAMI sorgente/storage. Poi build/deploy. |
| Nessun hosting. | Eseguire la prima installazione del README, dopo aver predisposto risorse esterne e connettivita privata. |
| Clone nuovo, hosting esistente ma nessuno stato locale. | Usare il target esplicito. Soltanto scegliendo la modalita Terraform serve collegare il backend/stato corretto; non creare una seconda infrastruttura per ottenere gli output. |

### Come pubblicare da PowerShell senza Terraform

Per il primo caso, dalla radice del checkout aggiornato e dopo aver sostituito i tre segnaposto con i riferimenti del cliente:

```powershell
$ErrorActionPreference = 'Stop'
if ((git branch --show-current) -ne 'feature/multiple-lb_logging-actions-and-info-check-rg') { throw 'Checkout non corrispondente alla versione richiesta.' }
git pull --ff-only origin feature/multiple-lb_logging-actions-and-info-check-rg
if ($LASTEXITCODE -ne 0) { throw 'Aggiornamento Git non riuscito; verificare autorizzazione al repository privato.' }
./scripts/build.ps1 -PackagePath './out/function-app.zip'
./scripts/deploy.ps1 `
    -SubscriptionId '<ID-SUBSCRIPTION-HOSTING>' `
    -ResourceGroupName '<RESOURCE-GROUP-HOSTING>' `
    -FunctionAppName '<NOME-FUNCTION-APP>' `
    -PackagePath './out/function-app.zip'
```

La build usa `-PackagePath` come destinazione del ZIP; il deploy usa lo stesso percorso come sorgente del pacchetto. La subscription e quella dell'hosting, il Resource Group contiene la Function App e il nome identifica l'app intera, non una delle sue tre funzioni. Il deploy ricava da Azure l'hostname effettivo: non occorre passare l'URL.

### Come pubblicare da Bash senza Terraform o PowerShell

Installare le utility native e verificare branch, autenticazione, rete e destinazione come descritto nel [README](../README.md#come-eseguire-build-e-deployment-da-bash-senza-powershell). Sullo stesso hosting gia pronto:

```bash
if bash ./scripts/build.sh --package-path "./out/function-app.zip" &&
   bash ./scripts/deploy.sh \
    --subscription-id "<ID-SUBSCRIPTION-HOSTING>" \
    --resource-group-name "<RESOURCE-GROUP-HOSTING>" \
    --function-app-name "<NOME-FUNCTION-APP>" \
    --package-path "./out/function-app.zip"; then
    printf '%s\n' 'Build e deployment verificati.'
else
    printf 'Procedura fallita, exit code %s. Deployment non confermato: leggere gli errori sopra.\n' "$?" >&2
fi
```

Il blocco e per uso interattivo: se la build fallisce, il deploy non parte e il terminale rimane aperto. Non incollare `set -euo pipefail` nella shell chiamante e non avviare gli script con `source`, `.` o `exec`. Se il terminale si e gia chiuso, seguire la [raccolta dell'errore della build](../README.md#come-raccogliere-lerrore-se-la-build-chiude-il-terminale) prima di ritentare il deploy.

La [tabella unica dei parametri PowerShell/Bash](../README.md#come-pubblicare-senza-terraform-con-i-parametri-del-target) documenta funzione, obbligatorieta e default. Per una build senza nuovi download usare `--skip-module-download` soltanto dopo aver predisposto `out/module-cache`; PowerShell usa invece `-SkipModuleDownload` con i suoi moduli locali. I due `--help` Bash mostrano la sintassi senza operazioni Azure.

La build Bash non esegue script PowerShell, non usa i moduli scaricati dalla build PowerShell e non richiede `pwsh` installato. Il deploy non avvia attivazioni: controlla la presenza delle tre funzioni e invia soltanto richieste incomplete che devono essere rifiutate con HTTP 400.

**Collaudo storico del 20 ottobre:** 40 test locali e build reale in Ubuntu senza PowerShell installato; build e deploy effettivi dal lab privato con PowerShell escluso dal `PATH`. Tre funzioni, 400 previsti, report esistente schema 2 e quattro classi verificati. Code vuote prima/dopo, nessuna replica nuova, app del ramo padre invariata e postazione riportata deallocata.

**Collaudo della nuova modalita senza Terraform:** il 21 ottobre, fra le 00:30:55 e le 00:34:22 ora italiana, PowerShell e Bash hanno generato e pubblicato realmente due ZIP distinti con i parametri espliciti, senza Terraform nel `PATH`. Entrambi i deployment Azure sono riusciti; dopo ciascuno sono stati verificati tre funzioni, i due 400 attesi e lo storico schema 2 con le quattro classi. Le code erano vuote prima, fra le due pubblicazioni e dopo; nessuna nuova replica e stata avviata. Postazione nuovamente deallocata. Sono passati anche 37 test PowerShell e 68 Bash, con compatibilita della modalita precedente. I [dettagli e limiti del collaudo reale](../README.md#quale-collaudo-reale-ha-superato-la-modalita-senza-terraform) non sostituiscono i prerequisiti del cliente.

### Come mantenere la modalita Terraform precedente

Il deploy senza i tre parametri del target continua a leggere gli output Terraform. Se lo stato e altrove usare `-TerraformDirectory` in PowerShell oppure `--terraform-directory` in Bash. Questi parametri non vanno mescolati con il target esplicito; input parziali non attivano un recupero automatico da Terraform. Non servono installazione, stato o output Terraform per i comandi espliciti sopra.

### Quando predisporre anche l'infrastruttura

**Soltanto se l'infrastruttura va creata o aggiornata**, seguire invece questa sequenza completa:

1. Configurare gli input ambientali esistenti e i prerequisiti secondo il [README](../README.md#come-distribuire-la-soluzione).
2. Inizializzare, validare ed esaminare il piano Terraform; applicarlo solo dopo approvazione, verificando scope, creazioni, modifiche e costi.
3. Dalla rete privata eseguire `./scripts/build.ps1` e `./scripts/deploy.ps1`, oppure `bash ./scripts/build.sh` e `bash ./scripts/deploy.sh` senza PowerShell.
4. Verificare tutte e tre le funzioni e i due HTTP 400 senza `sessionId`; questo non avvia replica.

Il pacchetto contiene versioni fissate dei moduli Azure, senza `local.settings.json`. Non cambiare dipendenze durante la riunione. Non abilitare storage key o accesso pubblico, non introdurre `WEBSITE_RUN_FROM_PACKAGE` e non usare un pacchetto di un'altra versione come scorciatoia.

I comandi Terraform richiedono lo stato e gli input dell'ambiente corretto; non copiarli dal lab interno. Il deployment non prepara reti o applicazioni del sito DR al posto del loro gestore.

**Verifica storica dello script allegato:** il 20 ottobre sono stati eseguiti build e deploy PowerShell precedenti, con lo stesso `deploy.ps1` di 37 righe, su hosting CSV/log privato gia configurato. PowerShell 7.6.1 Linux e Azure CLI 2.91.0: deployment riuscito, tre funzioni verificate, 400 previsti, schema 2 riletto, code vuote e nessuna replica avviata. Quella prova riguarda la versione precedente; la modalita parametrizzata usa gli script correnti. Rete, ruoli e destinazione del cliente restano da confermare; lo stato Terraform serve solo nella modalita precedente.

## Resoconto aggiornato: quali informazioni del testo precedente restano valide

### Stato delle versioni e architettura

| Quale consegna e stata verificata | Quale stato mantiene |
|---|---|
| `delivery`, versione `30c5656`. | Contiene multisubscription e copia diretta senza snapshot, locale/remoto allineati. I due vecchi rami remoti sono stati eliminati dopo la verifica di integrazione. |
| `feature/async-session-id`, versione `665ae4a`. | Introduce starter HTTP, Queue/worker e stato persistente per UUID del client. Non e stato integrato in delivery. |
| `feature/async-session-id-csv-log`, funzionalita verificata alla versione `84e25b7`. | Aggiunge le cinque colonne, le quattro priorita e il report cliente. Padre locale/remoto e sua app invariati. Le versioni successive della sola guida non cambiano il codice applicativo. |

Restano validi rete privata senza fallback pubblico, due UAMI separate, nessun database aggiuntivo, messaggio di sessione accettato prima del 202, piano immutabile, acquisizione condizionale con ETag e nessuna lettura di successi vecchi da log recenti. Un ETag identifica la versione del documento usata per controllare aggiornamenti concorrenti.

I controlli della Function riguardano presenza/accessibilita dei prerequisiti necessari alle creazioni; non riconciliano configurazioni di sicurezza, Load Balancer o sistemi esterni. La copia resta diretta dai dischi primari, cifrata con il DES DR, senza snapshot.

### Risultati storici e risultati dell'ultima versione

| Quale prova appartiene a quale versione | Quali risultati sono documentati |
|---|---|
| Ramo asincrono iniziale, una VM e due dischi. | Sei suite locali e 14 test Terraform; nove controlli negativi, 19 sul preflight e 15 sulla creazione/replay/risorse. HTTP 202 in 4,45 s, worker 52,33 s, completamento 61,23 s dalla conferma della coda. |
| Nuova versione CSV/log, quattro VM e quattro dischi OS. | Regressioni preservate; 28 controlli CSV/ordine e 33 sul JSON/metadati, 14 test Terraform, 12 controlli negativi reali, 688 asserzioni su 22 osservazioni e risorse. Confronto di 35 nomi/tipi col riferimento cliente e quattro log completi verificati. |
| Ordine reale della nuova versione, input inverso. | Creazioni in Coordinated Universal Time (UTC), riferimento orario universale: sistemico 17:38:34, altamente critico 17:39:07, critico 17:39:28, non critico 17:39:50 del 20 ottobre 2026. |
| Tempi della nuova prova. | HTTP 202 in 3,01 s, worker 133,65 s, completamento 142,80 s dalla conferma della coda; non sono garanzie di prestazione o RTO. |

Restano validi i correttivi per payload nativo PowerShell della Queue, `409 BlobAlreadyExists` nella registrazione condizionale e percorsi Blob case-sensitive. I test attendono il guest agent anziche presumerlo pronto istantaneamente.

### Limiti e stato finale da non omettere

- Due coppie Azure reali richiedono quattro subscription utilizzabili: non sono state provate; due coppie e omonimi sono coperti nei test simulati.
- Sessioni diverse sullo stesso workload richiedono coordinamento esterno: nessun lock distribuito e stato aggiunto.
- Il riuso dei dischi non li aggiorna e il riuso di VM spente non le avvia. Consistenza multi-disco, salute applicativa e ripristino geografico non sono certificati.
- Alcune prime prove negative hanno incontrato 503 del frontend, registrati e ritentati in modo limitato; le prove positive finali non hanno richiesto tali retry.
- Nel lab della nuova versione quattro sorgenti, quattro VM DR e postazione sono state deallocate. Function e storage restano distribuiti; dischi, Private Endpoint e log possono continuare a costare.
- Formato/validate/test Terraform sono passati. Il checker `check-terraform-direct-values` aveva segnalato l'interfaccia ambientale preesistente, quindi non e dichiarato PASS. Il vecchio input privato `dr_subscription_id` generava un avviso locale; il codice non lo usa e il clone isolato non aveva quell'avviso.

## Cosa ho dato per scontato

La procedura principale usa un'app gia distribuita e un ambiente approvato; non presume che il cliente abbia accesso al lab interno. Tipo di prova, tenant, scope, ruoli e destinazione vuota/riuso vanno concordati prima. Non si presume salute applicativa dal solo SUCCEEDED.

## Le 3 domande che ti verrebbe da farmi

1. **Come provo tutte e tre le funzioni se solo due hanno un URL?** Invoke avvia il lavoro tramite Queue; stato, timestamp, risorse e log dimostrano l'esecuzione del worker. Get-DRStatus viene provata sia con GET sia con POST.
2. **Posso dimostrare una nuova creazione con le VM DR deallocate del vecchio test?** No: quelle sono risorse esistenti. Avviarle per un test di riuso oppure preparare prima una destinazione vuota autorizzata.
3. **Il cliente deve vedere la key o averla nel CSV?** No: il client deve custodirla in memoria e inviarla nell'header. Nel CSV e nei file di contesto non va inserita.

## Fonti

- Passi 1, 7-15 e resoconto: [README](../README.md), [starter](../function-app/Invoke-DRReplication/run.ps1), [worker](../function-app/Process-DRSession/run.ps1), [stato](../function-app/Get-DRStatus/run.ps1), [modulo sessioni](../function-app/Modules/DRSessions/DRSessions.psm1), [collaudo delle priorita](../tests/live-csv-priority.ps1).
- Passi 2-5: [Azure Functions networking](https://learn.microsoft.com/azure/azure-functions/functions-networking-options), [autorizzazione tramite function key](https://learn.microsoft.com/azure/azure-functions/functions-bindings-http-webhook-trigger#authorization-level), [ruoli dati Storage](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/storage).
- Passi 6-16: [Invoke-RestMethod](https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/invoke-restmethod?view=powershell-7.6), [pattern di richiesta/risposta asincrona](https://learn.microsoft.com/azure/architecture/patterns/asynchronous-request-reply), [Queue trigger e riconsegne](https://learn.microsoft.com/azure/azure-functions/functions-bindings-storage-queue-trigger).
- Passi 14 e 17: [copia diretta dei dischi](https://learn.microsoft.com/azure/virtual-machines/scripts/copy-managed-disks-to-same-or-different-subscription), [durata esecuzioni e limite HTTP](https://learn.microsoft.com/azure/azure-functions/functions-scale#function-app-timeout-duration).
- Deployment: [scripts/deploy.ps1](../scripts/deploy.ps1), [build Bash nativa](../scripts/build.sh), [deploy Bash nativo](../scripts/deploy.sh), [pubblicazione Azure Functions](https://learn.microsoft.com/azure/azure-functions/deployment-zip-push?pivots=flex-consumption-plan), [download manuale dei moduli](https://learn.microsoft.com/powershell/gallery/how-to/working-with-packages/manual-download?view=powershellget-3.x).
- Target esplicito e parametri: [lettura dei riferimenti della Function App](https://learn.microsoft.com/cli/azure/functionapp#az-functionapp-show), [parameter set PowerShell](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_parameter_sets?view=powershell-7.6), [tabella dei parametri nel README](../README.md#come-pubblicare-senza-terraform-con-i-parametri-del-target).
- Rete e cronologia: [mapping e prerequisiti](../function-app/Modules/DRCore/DRCore.psm1), [audit condiviso](../function-app/Modules/DRAudit/DRAudit.psm1), [diagnostica prima del worker](../tests/submission-diagnostics.ps1), [collaudo Azure isolato](../tests/live-multiple-load-balancers.ps1).

## Glossario per la conduzione del test

- **SessionId:** UUID dell'attivazione scelto dal client prima della POST; non e una key.
- **Worker:** funzione che consuma il messaggio della Queue ed esegue la replica.
- **Preflight:** lettura preventiva dei prerequisiti necessari, prima delle creazioni workload.
- **RTO:** obiettivo temporale della classe di priorita, non un tempo garantito dal codice.
- **ResourceKey:** identificativo stabile subscription/gruppo/VM usato nel report cliente.
- **SUCCEEDED:** esito storico delle operazioni del codice; non verifica continua dello stato o dell'applicazione.

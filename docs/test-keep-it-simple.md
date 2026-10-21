## Storage
**I container conservano file; le code conservano messaggi che fanno partire il lavoro.** Queste sono le risorse applicative, con i nomi predefiniti:

| Quale risorsa è | A che cosa serve |
|---|---|
| **Container `app-package`** | Conserva il pacchetto ZIP del codice che Azure esegue nella Function App. |
| **Container `dr-configs`** | Conserva i CSV di input, caricati dal client prima di chiamare Invoke. |
| **Container `dr-logs`** | Conserva i log dettagliati delle operazioni su dischi, rete e VM, utili per diagnosticare gli errori. |
| **Container `dr-sessions`** | Conserva richiesta, piano e stato aggiornato di ogni sessione. **È la fonte letta da Get-DRStatus.** |
| **Coda `dr-activation`** | Trasporta il messaggio con `sessionId` che attiva la funzione di elaborazione. **Un messaggio riguarda un’intera sessione/CSV, non una singola VM.** |
| **Coda `dr-activation-poison`** | Raccoglie i messaggi che il runtime non riesce a elaborare dopo **5 tentativi**, per consentire l’analisi e l’intervento dell’operatore. Non è l’elenco di tutte le VM fallite. |

Fonti: `architettura e nomi delle risorse`, `configurazione dei tentativi della coda`.


**Per usare lo stesso percorso degli esempi, carica il CSV qui** — assumendo il container predefinito `dr-configs`:

**URL completo:**
```text
https://<STORAGE-ACCOUNT-CLIENTE>.blob.core.windows.net/dr-configs/configurations/vms.csv
```

**Storage Path dentro lo Storage Account:**
```text
dr-configs/configurations/vms.csv
```

**Parametro da passare a Invoke, senza container:**
```json
"csvBlobPath": "configurations/vms.csv"
```

**Nell’allegato manca il nome dello Storage Account cliente**, quindi non posso sostituire quel segnaposto senza inventarlo. Per conoscere endpoint e container effettivamente configurati sulla Function:

```bash
az functionapp config appsettings list \
  --subscription '<ID-SUBSCRIPTION-HOSTING>' \
  --resource-group '<RESOURCE-GROUP-HOSTING>' \
  --name '<NOME-FUNCTION-APP>' \
  --query "[?name=='CSV_STORAGE_CONNECTION__blobServiceUri' || name=='CSV_CONTAINER_NAME'].[name,value]" \
  -o table
```

L’URL finale è **endpoint Blob + `/` + container configurato + `/configurations/vms.csv`**. Se il container è personalizzato, sostituisci `dr-configs` con quel nome.

Fonte: `configurazione letta dalla Function`, [formato degli URL Blob Microsoft](https://learn.microsoft.com/azure/storage/blobs/storage-blobs-introduction#blob-storage-resources).


## Il CSV da usare 

Usa **`vms-priorities.csv`**. Contiene quattro VM di esempio, una per priorità, con queste colonne obbligatorie:

```csv
Criticita,Acronimo,SourceSubscription,SourceResourceGroup,SourceVmName
```

Sostituisci i riferimenti fittizi con quelli delle **VM sorgenti** del cliente. L’esempio è volutamente in ordine inverso: la Function deve comunque rispettare la priorità prevista.


## Come si svolge l’attivazione

1. **Il client carica il CSV in Azure Blob Storage**, nel container CSV configurato per la Function.
2. **Il client genera `sessionId`**, un Universally Unique Identifier (UUID), cioè un identificativo univoco dell’attivazione, da conservare per le consultazioni successive.
3. **Il client chiama `Invoke-DRReplication`**, passando `sessionId` e `csvBlobPath`, il percorso del file dentro il container.
4. **Invoke valida richiesta e CSV** e registra il piano della sessione, che non cambia se successivamente viene modificato il file.
5. **Invoke accoda la sessione in Azure Storage Queue** e, soltanto dopo la conferma dell’accodamento, restituisce **HTTP 202 Accepted** per la nuova richiesta.
6. **`Process-DRSession`, la funzione attivata dalla coda, verifica i prerequisiti Azure**. Se mancano, conclude con errore senza creare risorse workload.
7. **Il worker esegue le attivazioni** nell’ordine **sistemico → altamente critico → critico → non critico**, aggiornando stato e log. A parità di priorità conserva l’ordine del CSV.
8. **Il client consulta `Get-DRStatus`** con lo stesso `sessionId`, fino allo stato finale `SUCCEEDED` oppure `FAILED`.

## Esempi semplici con curl

Questi comandi sono per **Bash su Linux o Windows Subsystem for Linux (WSL)**. Eseguili da una postazione che raggiunga la Function tramite rete privata, dopo aver caricato il CSV.

### Preparare i riferimenti una sola volta

```bash
API_URL='https://<hostname-effettivo-function-app>/api'
FUNCTION_KEY='<function-key>'
CSV_BLOB_PATH='configurations/vms.csv'

SESSION_ID="$(cat /proc/sys/kernel/random/uuid)"
printf 'sessionId da conservare: %s\n' "$SESSION_ID"
```

- `API_URL` è l’indirizzo effettivo della Function, **incluso `/api`**.
- `FUNCTION_KEY` è il segreto di autenticazione, inviato nell’header e non nell’URL.
- `CSV_BLOB_PATH` è il percorso del blob già caricato: **non un percorso locale, non un URL e senza il nome del container**. Deve rispettare maiuscole e minuscole.

### Chiamare Invoke

```bash
curl -sS -i -X POST "$API_URL/Invoke-DRReplication" \
  -H "x-functions-key: $FUNCTION_KEY" \
  -H 'Content-Type: application/json' \
  --data "{\"sessionId\":\"$SESSION_ID\",\"csvBlobPath\":\"$CSV_BLOB_PATH\"}"
```

**Risposta attesa per una nuova richiesta valida: `202 Accepted`.** Se perdi la risposta, ritenta con **lo stesso `sessionId` e CSV invariato**, senza generare un’altra sessione.

### Consultare Get-DRStatus

```bash
curl -sS -i "$API_URL/Get-DRStatus?sessionId=$SESSION_ID" \
  -H "x-functions-key: $FUNCTION_KEY"
```

**Risposta attesa: `200 OK`** con stato della sessione, risultati delle VM e contatori delle quattro classi. Ripeti questa GET, ad esempio ogni cinque secondi, fino a `status=SUCCEEDED` oppure `status=FAILED`.

## Cosa ho dato per scontato

La Function è già distribuita; il CSV è stato caricato nel container corretto; indirizzo, key e accesso privato sono disponibili. Gli esempi sono stati verificati offline: **non ho avviato una nuova attivazione DR**.

## Le 3 domande che ti verrebbe da farmi

1. **Il 202 significa che le VM sono pronte?** No: conferma l’accettazione e l’accodamento.
2. **Devo inviare il contenuto del CSV nella POST?** No: soltanto il suo percorso nel container.
3. **Il JSON allegato dimostra un’esecuzione reale?** Coincide con `status.json di esempio`: illustra il formato, non certifica una nuova esecuzione.

## Fonti

- Passi 1–5: `validazione del CSV e registrazione della sessione`, `Invoke`.
- Passi 6–7: `implementazione del worker`.
- Passo 8: `Get-DRStatus`; [Microsoft: richiesta/risposta asincrona](https://learn.microsoft.com/azure/architecture/patterns/asynchronous-request-reply).

## Glossario

- **Worker:** funzione che elabora il lavoro ricevuto dalla coda.
- **Blob:** file conservato in Azure Blob Storage.
- **SessionId:** identificativo generato dal client per correlare richiesta, avanzamento e risultato.
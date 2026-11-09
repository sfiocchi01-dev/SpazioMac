# SpazioMac

**A native, read-only macOS disk usage explorer.**  
Un'app nativa per capire quali directory occupano più spazio sul Mac.

> **Stato: prima versione, 0.1.** Il motore ha controlli automatici; interfaccia, prestazioni su dischi grandi e permessi macOS richiedono ulteriori prove. Non è un programma di pulizia.

## Funzionalità

- Albero delle directory espandibile, ordinato per dimensione.
- Dimensione **logica** e **allocata su disco**, con percentuali del totale analizzato.
- Ricerca delle cartelle per nome.
- Elenco ricorsivo dei file della directory selezionata e di tutte le sue sottocartelle, aggiornato in background a ogni cambio di selezione.
- Scansione in background con annullamento.
- Apertura delle voci nel Finder.
- Segnalazione di errori, directory non accessibili e scansioni parziali.
- Nessuna eliminazione, rete, account, pubblicità o telemetria.

Scritto in **SwiftUI e AppKit**, senza dipendenze esterne.

## Requisiti

- macOS 13 o successivo.
- Per compilare: Swift 5.9+ e SDK macOS, tramite Xcode o Command Line Tools.
- Il bundle generato è per l'architettura del Mac di compilazione, non automaticamente universale.

## Compilare

Dalla directory del repository:

```sh
swift run SpazioCoreCheck
bash build.sh
open dist/SpazioMac.app
```

Per installare nella cartella Applicazioni dell'utente:

```sh
bash build.sh --install
open "$HOME/Applications/SpazioMac.app"
```

L'installazione rifiuta di sovrascrivere una copia esistente. Per aggiornare, chiudi l'app e sostituisci esplicitamente il vecchio bundle dopo averlo eventualmente conservato.

La build usa una **firma ad hoc locale**, non Developer ID o notarizzazione Apple. Non disabilitare Gatekeeper o altre protezioni per eseguire copie di origine non verificata.

## Uso

1. Premi **Scegli cartella** o Cmd+O e seleziona una directory o un volume.
2. Espandi l'albero per individuare le directory più grandi.
3. Seleziona **Su disco** o **Logica**: l'ordinamento segue la misura scelta.
4. Filtra per nome, quindi usa **Mostra nel Finder**; anche il doppio clic rivela una directory.
5. Cmd+R aggiorna la scansione. **Annulla** interrompe il lavoro senza modificare i file.

L'albero mostra le directory. La tabella inferiore mostra **tutti i file e i link della directory selezionata, comprese tutte le sue sottocartelle**, senza il precedente limite di 100 file. A ogni cambio di selezione la lista precedente viene svuotata e una nuova lettura ricorsiva parte in background; eventuali risposte tardive della selezione precedente vengono ignorate. I file delle cartelle sorelle o esterne non sono inclusi. La colonna **Percorso relativo** distingue i file omonimi e mostra la posizione rispetto alla selezione. La lista è ordinata per la misura scelta (Su disco o Logica). La ricerca superiore filtra le cartelle, non questa lista, e non legge il contenuto dei file.

Le dimensioni dei singoli file sono metadati letti al momento della selezione: possono differire dalla scansione precedente se il filesystem è cambiato. Gli hard link sono mostrati come voci distinte con la propria dimensione e i link simbolici con la dimensione del collegamento stesso, mai del target; la somma delle righe non deve essere interpretata come spazio esclusivo o necessariamente coincidere con il totale aggregato dell'albero.

### Permessi macOS

Alcune directory richiedono consenso. Se necessario, concedi consapevolmente **Impostazioni di Sistema → Privacy e sicurezza → Accesso completo al disco → SpazioMac**, poi chiudi e riapri l'app.

L'app non richiede root e non concede permessi da sola. Anche Accesso completo al disco non supera ogni restrizione Unix o SIP. Senza accesso, i risultati restano parziali e vengono segnalati.

## Come interpretare le dimensioni

| Misura | Significato |
| --- | --- |
| Logica | Dimensioni dei file regolari, deduplicando gli hard link nella scansione |
| Su disco | Blocchi allocati riportati da `lstat.st_blocks × 512`, inclusi i blocchi propri di directory e link |
| Quota | Percentuale del totale contabilizzato nella scansione, non della capacità del disco |

**Su APFS, spazio allocato non significa spazio liberabile.** Cloni, snapshot, compressione e blocchi condivisi impediscono un'attribuzione fisica esclusiva dei dati a ogni cartella.

Altri limiti importanti:

- Gli hard link contano una sola volta in byte; i byte vengono attribuiti alla prima directory incontrata. Le voci file/link sono invece contate separatamente.
- I link simbolici non vengono seguiti. La directory radice scelta viene risolta al percorso effettivo.
- Sono incluse cartelle nascoste e contenuti dei bundle `.app`.
- I file cloud riflettono i metadati disponibili: l'app non apre né richiede il download dei contenuti. Il provider può comunque essere coinvolto nell'enumerazione.
- La scansione non è uno snapshot: i file possono cambiare mentre viene eseguita.
- I risultati non rappresentano automaticamente tutta la capacità usata di un contenitore APFS.
- Su filesystem remoti o bloccati, l'annullamento può attendere il ritorno della singola chiamata in corso.

### Volumi e directory escluse

Per default **Resta sul volume selezionato** evita di attraversare dispositivi differenti. Su APFS, una scansione di `/` può quindi escludere i dati utente sul volume Data: scegli direttamente la cartella utente o `/System/Volumes/Data`.

Disattivare l'opzione può contare più volte dati raggiungibili tramite mount/firmlink. Le esclusioni e gli errori sono segnalati, non considerati spazio zero valido.

Il motore conserva fino a **200.000 directory** e i primi **500 dettagli di errore**. L'app non conserva una lista globale dei file durante la scansione iniziale: legge ricorsivamente il sottoalbero selezionato su richiesta. La lista selezionata non è limitata a 100 elementi; sottoalberi con moltissimi file possono quindi richiedere più tempo e memoria. La lettura rispetta la scelta sui volumi usata nell'ultima scansione, segnala errori ed esclusioni e non segue link simbolici verso altre directory. Raggiungere il limite directory nella scansione produce un risultato dichiaratamente incompleto.

## Verifiche e sviluppo

```sh
swift run SpazioCoreCheck
swift build --product SpazioMac
bash build.sh
```

I controlli usano fixture temporanee e coprono:
- aggregazione annidata e file nascosti;
- hard link;
- link simbolici ciclici;
- file sparsi;
- annullamento immediato e limite directory;
- top file del motore e rifiuto di radici non valide;
- elenco ricorsivo del sottoalbero selezionato, percorsi relativi, file omonimi, file nascosti e oltre 100 voci;
- hard link, link simbolici a directory e link interrotti nella lista;
- cambio di directory, directory vuote/inesistenti e annullamento della lettura.

Sono un target eseguibile, utilizzabile anche senza XCTest nei Command Line Tools. La workflow GitHub Actions esegue controlli e build su macOS; la sua esecuzione remota va verificata dopo la pubblicazione.

```text
Sources/SpazioCore/Scanner.swift      Scansione e aggregazione
Sources/SpazioCore/DirectoryFiles.swift Elenco ricorsivo dei file selezionati
Sources/SpazioMac/App.swift           Interfaccia e Finder
Tests/SpazioCoreTests/               Controlli del motore
Resources/                          Bundle e icona
build.sh                            Pacchetto .app
```

Prima di contribuire leggi [CONTRIBUTING.md](CONTRIBUTING.md). Per problemi di sicurezza consulta [SECURITY.md](SECURITY.md).

**Privacy dei report:** percorsi, nomi di file e screenshot possono contenere dati personali. Usa fixture o anonimizza gli allegati.

## Possibili sviluppi

- Treemap interattiva.
- Esportazione CSV/JSON.
- Confronto fra scansioni.
- Filtri e vista completa dei file.
- Test UI, accessibilità e misure di prestazione su grandi directory.

Queste funzionalità non sono ancora implementate.

## Licenza e indipendenza

Copyright (c) 2026 SpazioMac contributors.

Distribuito sotto [GNU General Public License versione 3](LICENSE), **GPL-3.0-only**. Il software è fornito senza garanzie; copia, modifica e ridistribuzione sono consentite alle condizioni della licenza. Distribuendo i binari occorre fornire anche il corrispondente codice sorgente secondo la GPLv3.

SpazioMac è un progetto indipendente. TreeSize è stato un riferimento funzionale: non ne incorpora codice, icone o risorse e non è affiliato ai suoi autori. L'icona del progetto è generata dal sorgente incluso. Le denominazioni di prodotti di terzi appartengono ai rispettivi titolari.

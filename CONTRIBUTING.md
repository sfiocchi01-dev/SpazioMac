# Contribuire a SpazioMac

Grazie! Il progetto è una prima versione nativa macOS. Sono benvenuti bug report, test, miglioramenti di accessibilità e prestazioni.

## Prima di proporre una modifica

- Per modifiche ampie, apri una discussione o una issue sul comportamento desiderato.
- Mantieni il motore di scansione separato dall'interfaccia.
- Non introdurre eliminazioni, modifiche dei file analizzati, telemetria o nuovi permessi senza una discussione esplicita.
- Non aggiungere dipendenze senza motivazione e verifica della relativa licenza.
- Descrivi i limiti delle misure APFS: “allocato” non equivale a spazio recuperabile.

## Ambiente e controlli

Servono macOS 13+ e Swift 5.9+ con SDK macOS, forniti dai Command Line Tools o da Xcode.

```sh
swift run SpazioCoreCheck
swift build --product SpazioMac
bash build.sh
```

Il target SpazioCoreCheck usa fixture temporanee e non richiede XCTest. Ogni controllo fallito termina con un codice non zero. Per nuovi casi del filesystem, aggiungi una fixture deterministica, senza accedere alle directory personali di chi esegue i test.

Prima di inviare una pull request:
- esegui i controlli;
- verifica almeno avvio, scelta cartella, annullamento e navigazione dell'albero;
- descrivi cosa è stato verificato e cosa non lo è stato;
- non includere .build, bundle compilati o chiavi di firma.

## Privacy nei report

Percorsi, nomi di file, screenshot e log possono contenere dati privati. Usa cartelle di prova e anonimizza nomi utente, server e documenti. Non allegare elenchi del disco personale o credenziali.

I contributi sono distribuiti con la licenza GPL-3.0-only del progetto; non serve una CLA separata. Mantieni attribuzioni e licenze di eventuale codice di terze parti.

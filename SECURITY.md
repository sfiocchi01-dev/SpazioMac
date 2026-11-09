# Sicurezza e privacy

SpazioMac è in fase iniziale. Non sono promessi tempi di risposta o supporto a versioni precedenti.

Il motore deve limitarsi a leggere metadati: non deve modificare, cancellare, aprire il contenuto o inviare in rete i file analizzati. Segnala qualsiasi comportamento che violi questi confini.

Per una vulnerabilità sensibile, usa la segnalazione privata di GitHub (**Security → Report a vulnerability**) se disponibile. Se non è abilitata, chiedi un canale privato senza pubblicare dettagli tecnici sfruttabili. Non sono ancora definiti un indirizzo di sicurezza dedicato o una procedura di risposta con tempi garantiti.

Non pubblicare percorsi personali, credenziali, dump del disco o screenshot non anonimizzati nelle issue.

## Permessi

L'Accesso completo al disco deve essere concesso consapevolmente dall'utente. Il progetto non deve richiedere root, aggirare TCC/SIP o ottenere autorizzazioni in modo automatico.

La firma ad hoc prodotta da build.sh serve allo sviluppo locale: non è una firma Developer ID né una notarizzazione Apple. Valuta codice e provenienza prima di eseguire un bundle scaricato.

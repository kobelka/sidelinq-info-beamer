# Sidelinq Turnier für info-beamer

Live-Anzeige für Turniere aus dem [Sidelinq](https://sidelinq.de)-Turnierplaner auf einem Raspberry Pi mit [info-beamer hosted](https://info-beamer.com). Die Anzeige läuft ohne Browser und ist deshalb auch auf einem **Raspberry Pi Zero 2 W** flüssig.

Zu sehen sind dieselben Inhalte wie in der Beamer-Ansicht von Sidelinq:

- laufende Spiele mit Spielstand je Feld
- die nächsten Spiele mit Uhrzeit und Feld
- die letzten Ergebnisse
- Tabellen bzw. K.O.-Runden, die alle 15 Sekunden durchwechseln
- ein QR-Code zur Live-Seite fürs Handy

Neue Ergebnisse blinken kurz auf. Ist das Netz weg, bleibt der letzte Stand stehen, oben rechts steht dann „Stand … Uhr“.

## Einrichtung

1. Bei info-beamer.com anmelden und den Raspberry Pi einrichten (ein Gerät ist kostenlos).
2. Unter **Packages → Add Package** diese Adresse eintragen: `https://github.com/kobelka/sidelinq-info-beamer`
3. Aus dem Paket ein **Setup** anlegen und den **Beamer-Link** aus Sidelinq einfügen. Du findest ihn in Sidelinq im Turnier unter „Für den Fernseher oder Beamer in der Halle“, z. B. `https://sidelinq.de/t/dein-turnier/beamer`.
4. Das Setup dem Pi zuweisen.

Für das nächste Turnier einfach den Link im Setup austauschen.

### Beamer-Link aus Sidelinq

Der Link zur Beamer-Ansicht des Turniers. Der normale Turnier-Link (`https://sidelinq.de/t/dein-turnier`) funktioniert auch. Das Turnier muss in Sidelinq veröffentlicht sein.

## Wie es funktioniert

Der Dienst (`service`, Python) holt alle 10 Sekunden die öffentlichen Turnierdaten von `https://sidelinq.de/api/public/tournament-beamer/<turnier>`, lädt Vereinslogos einmal herunter und verkleinert sie. `node.lua` zeichnet die Anzeige mit der Grafikeinheit des Pi. Tabellen, Platzierungen und K.O.-Paarungen berechnet Sidelinq, das Paket zeichnet nur.

Es werden nur Daten abgerufen, die auch die öffentliche Turnierseite ohne Anmeldung zeigt (Teamnamen, Logos, Spielzeiten, Felder, Ergebnisse). Spielerdaten gibt es dort nicht.

## Lizenz

Schrift: [Inter](https://github.com/rsms/inter) unter der SIL Open Font License 1.1 (`OFL-Inter.txt`).

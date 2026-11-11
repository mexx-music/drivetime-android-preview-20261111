# DriveTimeArrival / DriverRoute ETA – Projektprüfung

Stand: 17. September 2026

## 1. Was bereits gut funktioniert

- Flutter-Anwendung mit Web-/PWA- und Desktop-/Mobile-Zielplattformen.
- Google-Directions-Anbindung mit Proxy-Fallback für Web, OSM-Kartenansicht und Adressauflösung.
- Lokaler Fährfahrplan mit automatischer Erkennung, manueller Auswahl und Abfahrtszeiten.
- Eingaben für Zwischenziel, Durchschnittsgeschwindigkeit, bereits gefahrene Zeit und bisherige Einsatzzeit.
- Geschwindigkeitsprofile für 80 km/h, 70 km/h bei viel Bundes-/Landstraße
  und 60 km/h für Norwegen sowie eine automatische Routenauswertung.
- Grundlegende Berücksichtigung von 9-/10-Stunden-Lenktagen und 9-/11-Stunden-Tagesruhe.
- Responsive Eingabekomponenten und ein Debugmodus für technische Hinweise.

## 2. Gefundene und behobene Probleme

- `alreadyDrivenMin` wurde zur noch zu fahrenden Zeit addiert. Dadurch wurde die ETA zu spät. Der Wert reduziert jetzt die noch verfügbare ununterbrochene und tägliche Lenkzeit, verlängert aber nicht die Reststrecke.
- `dutyTimeOffsetMin` verschob den Startzeitpunkt rückwärts. Der reale Tourstart bleibt jetzt unverändert; die bisherige Einsatzzeit begrenzt stattdessen das verbleibende Tagesfenster.
- Lenkpausen wurden gesammelt am Ende eines großen Fahrblocks addiert. Jetzt entstehen einzelne Fahrt- und Pausenereignisse an der tatsächlichen 4,5-Stunden-Grenze.
- Bei exakt erreichter Zielzeit wurde teilweise noch eine unnötige Pause addiert. Am Ziel wird keine nachträgliche Pause mehr geplant.
- Eine Fährabfahrt in der Vergangenheit konnte die Rechenuhr zurücksetzen. Sie wird jetzt auf die Hafenankunft begrenzt und als Hinweis markiert.
- Eine lange Fährfahrt setzte 10-Stunden- und 9-Stunden-Wochenkontingente zurück. Qualifizierende Ruhe setzt jetzt nur den Tageszustand zurück.
- Fährzeit wurde allein anhand ihrer Dauer als Ruhe anerkannt. Sie zählt jetzt nur, wenn Schlafkabine/Liegeplatz bestätigt ist.
- Fehlende Fährsegment-Distanzen wurden pauschal mit 500 km ersetzt. Die App zeigt nun einen verständlichen Fehler, statt eine scheinpräzise ETA zu erfinden.
- Die manuell eingegebene Ersatzdistanz ging in einem zweiten Distanzabruf verloren. Sie wird jetzt tatsächlich als Fallback verwendet.
- Der Standard-Zählertest aus dem Flutter-Template prüfte die App nicht und schlug zwangsläufig fehl. Er wurde durch fachliche ETA-Tests ersetzt.
- Ein echter Google-Maps-API-Schlüssel war in `lib/secrets.dart`, im
  Android-Manifest und in der iOS-Info.plist und damit in der Git-Historie
  gespeichert. Web, Android und iOS lesen ihn jetzt nur noch aus lokaler
  Build-Konfiguration; der offengelegte Schlüssel muss in der Google Cloud
  Console rotiert werden.

## 3. Noch fehlende oder fachlich offene Funktionen

- Vollständiger Wochen-/Zweiwochenzustand (56 Stunden pro Woche, 90 Stunden in zwei Wochen), reduzierte Wochenruhe und Ausgleichsruhe brauchen gespeicherte historische Daten und einen Kalenderbezug. Aktuell kann nur eine bereits fällige reguläre 45-Stunden-Wochenruhe eingeplant werden.
- Eine geteilte tägliche Ruhezeit (3 + 9 Stunden) ist noch nicht modelliert.
- Mehrfahrerbetrieb, Nachtarbeitsgrenzen, Arbeitszeitrecht, nationale Abweichungen und Sonderfälle nach Artikel 12 sind nicht Bestandteil der ETA-Engine.
- Der Fährsonderfall mit bis zu zwei Unterbrechungen, zusammen höchstens einer Stunde, braucht Eingaben für Einschiffung/Ausschiffung und Ruheart. Die jetzige Berechnung erkennt nur eine ununterbrochene Zeit an Bord mit bestätigter Schlafmöglichkeit an.
- Fährdaten enthalten derzeit nur eine Zeitzone pro Route. Abfahrts- und Ankunftshafen brauchen getrennte IANA-Zeitzonen, damit lokale Uhrzeiten und Sommerzeitwechsel zuverlässig dargestellt werden.
- Zwischenstopps beeinflussen die Routendistanz, haben aber noch keine eigene Aufenthaltsdauer und deshalb kein eigenes Timeline-Ereignis.
- Persistenz mit `shared_preferences` ist als Abhängigkeit vorhanden, wird für Tour- und Wochenzustand aber noch nicht konsequent eingesetzt.
- Allgemeine Ländersperren für beliebige Länder und die automatische
  Kombination einer Serbien-Umfahrung mit eigenen Zwischenstopps sind noch
  nicht implementiert. Google Directions bietet keinen Länder-`avoid`-Parameter.

## 4. UI-/UX-Verbesserungen

- Die Eingabeseite verwendet jetzt dieselbe moderne Kartenoptik, Farbwelt und
  visuelle Hierarchie wie die Ergebnisdarstellung.
- Auf Desktop und im Querformat stehen Planung und Tourübersicht in zwei
  unabhängig scrollbaren Spalten nebeneinander; vor der ersten Berechnung
  erklärt eine kompakte Vorschau, welche Ergebnisse dort erscheinen.
- Auf Smartphone und schmalen Fenstern bleibt die Bedienung einspaltig und wird
  auf eine gut lesbare maximale Breite begrenzt.
- Eigenes DriverRoute-App-Icon für PWA/Homescreen, Android, iOS, macOS und
  Windows statt der Flutter-Standardgrafik.
- Start und Ziel stapeln sich auf Smartphones und stehen auf breiten Ansichten nebeneinander.
- Die Ortsvorschläge laufen im Web über den geschützten Karten-Proxy; technische
  HTTP-Fehler werden nicht mehr als Meldung in der Fahreransicht gezeigt.
- Der Startort kann über `Meine Position` aus der Browser-/Geräteposition
  übernommen werden; die Zielsuche wird anschließend auf diesen Bereich
  gewichtet.
- Es lassen sich bis zu zehn Zwischenstopps hinzufügen, in Fahrreihenfolge
  verschieben und wieder entfernen. Die Reihenfolge wird für Route, ETA und
  Kartenansicht beibehalten.
- `Serbien für die Route sperren` ist optional. Führt die ursprüngliche Route
  durch Serbien, wird für Griechenland–Österreich automatisch ein Korridor über
  Bulgarien, Rumänien und Ungarn angefordert. Die tatsächlichen Google-
  Streckenlinien werden gegen eine vereinfachte Natural-Earth-Ländergrenze
  geprüft. Bei fehlender oder weiterhin durch Serbien führender Route wird
  keine scheinbar gültige ETA erzeugt. Andere Relationen benötigen derzeit
  eigene Zwischenstopps; Grenzdaten und Verkehrsführung bleiben eine
  Planungshilfe und sind vor der Fahrt zu prüfen.
- Fahr- und Einsatzzeit werden jetzt als *verbleibende* Zeit eingegeben und in
  die bereits verbrauchten Werte der ETA-Engine umgerechnet. Die Eingabe von
  Stunden und Minuten erfolgt per Zahlentastatur statt per Zahlenrad;
  manuelle Abfahrtszeit wird in einem gemeinsamen Zeitdialog gewählt.
- Die automatische Fährplanung ist standardmäßig aktiv. Für erkannte
  Griechenland–Italien-Touren ohne Zwischenstopps vergleicht sie Patras und
  Igoumenitsa mit Brindisi, Bari, Ancona und Venedig anhand der erreichbaren
  Straßenbeine und der hinterlegten Überfahrtsdauer. Die Route wird ohne
  Hafen-Zwischenpunkte in die ETA übernommen. Hafen- und Zielstrecken müssen
  von Directions geliefert werden; bei fehlenden Daten erfolgt kein
  erfundener Fährvorschlag. Abfahrtszeiten und saisonale Verbindungen aus der
  lokalen Beispieldatei sind nicht live geprüft und müssen beim Betreiber
  verifiziert werden.
- Für eine optionale manuelle Fährabfahrt werden Datum und Uhrzeit jetzt mit
  einem gemeinsamen 24-Stunden-Zeitdialog statt zwei Zahlenrädern gewählt.
  Der funktionslose Testknopf wurde aus der offiziellen Oberfläche entfernt.
- Nordeuropa: Für Deutschland/Österreich–Schweden/Norwegen werden Kiel, Travemünde und
  Rostock mit Trelleborg, Malmö, Göteborg und Oslo verglichen. Für Lkw-Touren
  wird eine nach den hinterlegten Verbindungen erreichbare Fähre gegenüber der
  Strecke über Dänemark bevorzugt; innerhalb der Fährangebote zählt bislang
  Straßenstrecke plus Überfahrtsdauer, **kein** Live-Preis. Bei konkreten
  Hafenpaaren erhält die Direktverbindung Vorrang. Neu aufgenommen wurden
  [Finnlines Travemünde–Malmö](https://www.finnlines.com/routes/malmo-travemunde/)
  (ca. 9 h) und
  [Stena Line Kiel–Göteborg](https://www.stenaline.co.uk/routes/kiel-gothenburg)
  (ca. 14 h), jeweils in beiden Richtungen. TT-Line Kiel–Trelleborg wurde
  deaktiviert, weil die aktuelle
  [TT-Line-Routenübersicht](https://www.ttline.com/en/sweden-ferries)
  Kiel nicht als Hafen führt. Rostock–Trelleborg wird von
  [TT-Line](https://www.ttline.com/en/germany-ferries/trelleborg-rostock/)
  und [Stena Line](https://www.stenaline.se/rutter/trelleborg-rostock)
  bestätigt.
- Ein ungeprüfter Beispiel-Fahrplan wird nicht mehr zur Hafenwartezeit
  hochgerechnet. Ohne eingetragene gebuchte Abfahrt ist die Fähren-ETA nur
  eine frühestmögliche Schätzung ohne Wartezeit; Buchung, Fahrzeugzulassung,
  Preis und Abfahrt müssen separat beim Betreiber geprüft werden.
- Als ausdrücklich wählbare Alternative für Deutschland–Schweden ist die
  Route über Dänemark mit **zwei** kurzen Fähren enthalten:
  [Helsingborg–Helsingør (20 min)](https://www.oresundslinjen.com/freight)
  und [Rødby–Puttgarden (45 min)](https://freight.scandlines.com/freight-routes/puttgarden-rodby/).
  Die drei Straßenbeine werden separat geprüft und beide Fähren als eigene
  Timeline-Ereignisse geplant. Sie wird nicht automatisch statt der direkten
  Ostseefähre gewählt. Warte- und Check-in-Zeiten sind mangels gebuchter
  Abfahrten noch nicht enthalten; die ETA ist daher eine Untergrenze.
- Selten benötigte Eingaben sind eingeklappt; technische Fahrplanquellen erscheinen nur im Debugmodus.
- Nach der Berechnung steht zuerst eine Tourzusammenfassung mit Distanz, reiner Fahrzeit, Pausen/Ruhe und ETA.
- Der Tourablauf wird als typisierte Timeline mit Start, Fahrblöcken, Lenkpausen, Tankstopp, Tages-/Wochenruhe, Hafen, Wartezeit, Fähre und Ziel dargestellt.
- Fähren zeigen explizit, ob eine tägliche Ruhezeit erfüllt wurde.
- Der Berechnen-Button hat einen Ladezustand und verhindert Doppelberechnungen.
- Fehler werden als verständliche Meldungen ausgegeben; technische Details bleiben im Debugmodus.
- `Grafik teilen` und `Text teilen` öffnen jeweils eine eindeutige Auswahl für
  WhatsApp, E-Mail und weitere Apps; der Text kann dort zusätzlich kopiert
  werden.
- Zusätzlich lässt sich die vollständige gestaltete Tourübersicht samt
  Kennzahlen, Straßenmix, Pausen-Timeline und ETA als PNG-Grafik teilen. Im Web
  kann die Grafik auch direkt gespeichert werden. Fehlt WhatsApp im
  macOS-Teilen-Menü, wird zuerst das PNG gespeichert und im Dialog als Vorschau
  gezeigt. Die Grafik kann zusätzlich in die Bild-Zwischenablage kopiert werden;
  danach öffnet `Weiter zu WhatsApp` einen Chat ohne vorausgefüllten Text. Dort
  kann das Bild mit Einfügen eingesetzt oder die gespeicherte Datei angehängt
  werden. Ein WhatsApp-Link kann keine lokale Datei automatisch anhängen.
- Der PNG-Export verwendet auf iPhone und Desktop dieselbe 600-Pixel-Layoutbreite
  (bei normalen Touren in doppelter Bildauflösung), ohne die Bildschirmansicht
  zu verändern. Das reduziert das sehr schmale Hochformat in WhatsApp; bei
  langen Tourabläufen bleibt eine Vorschau mit seitlichen Flächen möglich.
- Debug-Schalter und technische Fahrplanprotokolle sind nur in
  Entwicklungs-Builds sichtbar und fehlen in der offiziellen Release-Version.

## 5. Überarbeitete Berechnungslogik

- Kontinuierliche Lenkzeit, tägliche Lenkzeit und bisherige Einsatzzeit sind getrennte Zustände.
- Die 45-Minuten-Pause wird nach spätestens 4,5 Stunden eingeplant; optional ist 15 + 30 Minuten in dieser Reihenfolge möglich.
- Ein 10-Stunden-Tag wird erst dann als verbraucht gezählt, wenn mehr als 9 Stunden gefahren werden.
- Tagesruhe setzt die Tageswerte zurück, nicht die wöchentlichen Ausnahme-Kontingente.
- Tankzeit wird konservativ als sonstige Arbeit behandelt und nicht automatisch als Lenkpause angerechnet.
- Alle sichtbaren Statuskarten werden aus derselben strukturierten Ereignisliste berechnet wie die Timeline.
- Im Automatikprofil wird jeder Google-Routenabschnitt anhand Distanz und
  Fahrtdauer ausgewertet. Daraus entstehen ein distanzgewichteter
  Planungsschnitt und eine sichtbare Schätzung des Anteils schneller,
  Haupt-/Bundesstraßen- und langsamer Abschnitte. Das funktioniert
  routenspezifisch auch in Norwegen, Bulgarien, Rumänien und Deutschland; eine
  Norwegen-Pauschale von 60 km/h greift nur ohne Routendaten. Der automatische
  Schnitt bleibt für die LKW-Planung auf höchstens 80 km/h begrenzt.
  Alternativ sind 80/70/60 km/h oder ein individueller Wert direkt wählbar.

## Fachliche Grundlage und Hinweis

Die implementierten Grundgrenzen orientieren sich an der Verordnung (EG) Nr. 561/2006 und den Erläuterungen der Europäischen Kommission:

- <https://eur-lex.europa.eu/eli/reg/2006/561/oj?locale=de>
- <https://transport.ec.europa.eu/transport-modes/road/social-provisions/driving-time-and-rest-periods_en>
- <https://transport.ec.europa.eu/transport-modes/road/mobility-package-i/driving-rest-times_en>

Die Anwendung ist eine Planungshilfe. Sie ersetzt keine Tachographenauswertung und keine rechtliche Prüfung des konkreten Einsatzes.

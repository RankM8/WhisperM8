import Foundation

/// Legt fest, wie viele Zeilen Scrollback ein Agent-Terminal vorhaelt.
///
/// **Warum das ueberhaupt eine Politik braucht** (Befund 03.08.2026): SwiftTerms
/// Default sind 500 Zeilen. Ist der Ringpuffer voll — bei einem laenger
/// laufenden Chat also immer —, wirft jede neue Ausgabezeile oben eine alte
/// hinaus. SwiftTerm zieht dabei `yDisp`, die Leseposition des Nutzers, um
/// genau 1 nach unten, damit der Text unter ihm stehen bleibt. Das ist
/// richtig, hat aber eine Kante: `yDisp` laeuft dadurch unaufhaltsam gegen 0,
/// und bei 0 ist der obere Anschlag erreicht.
///
/// Gemessen an einem Terminal 160x45 (Simulation gegen echtes SwiftTerm):
///
///     Scrollback   hochgescrollt um   Agent-Output bis zum Anschlag
///     500                100 Zeilen                    400 Zeilen
///     500                300 Zeilen                    200 Zeilen
///     10 000             300 Zeilen                   9700 Zeilen
///
/// Eine einzelne Claude-Antwort mit Tool-Ausgaben sind schnell 100–300 Zeilen.
/// Mit dem alten Default war der lesende Nutzer also nach EINER Antwort des
/// Agenten oben angeschlagen — und je weiter er hochscrollte, desto schneller.
/// Genau das war der Unterschied zwischen „normalen" Chats (man liest, waehrend
/// der Agent idle ist — kein Output, kein Trimmen) und Background-Agents bzw.
/// der Agents-View (Dauer-Output genau waehrend man liest).
///
/// Der Wert ist bewusst konfigurierbar, nicht hart verdrahtet:
/// `defaults write com.whisperm8.app agentTerminalScrollbackLines -int 20000`
/// (wirkt fuer neu geoeffnete Chats).
enum TerminalScrollbackPolicy {
    /// Default. Gewaehlt aus einer Messung von Nutzen gegen Speicher —
    /// Scrollback vollstaendig beschrieben (worst case), acht Grid-Panes
    /// 80x45 bzw. ein Vollbild-Chat 200x50:
    ///
    ///     Zeilen   Vorlauf*   8 Panes im Grid   ein Vollbild-Chat
    ///        500   200 Z.            12,6 MB              3,1 MB
    ///      2 000  1700 Z.            34,9 MB             10,6 MB
    ///      5 000  4700 Z.            85,0 MB             28,1 MB   <- Default
    ///     10 000  9700 Z.           166,8 MB             57,0 MB
    ///
    ///     * Zeilen Agent-Output, bis ein um 300 Zeilen hochgescrollter
    ///       Nutzer an den oberen Anschlag geschoben wird.
    ///
    /// 5 000 sind ~15–45 laengere Agent-Antworten Vorlauf, also das 23-Fache
    /// des alten Defaults, und bleiben im Grid unter 100 MB. 10 000 waeren mit
    /// 167 MB fuer eine dauerhaft laufende App zu teuer — wer den Platz hat,
    /// hebt den Wert per `defaults write` (siehe oben).
    static let defaultLines = 5_000

    /// Unter SwiftTerms eigenem Default gehen wir nicht — darunter faengt das
    /// Problem oben wieder an.
    static let minimumLines = 500

    /// Deckel gegen Vertipper in `defaults write`. 200 000 Zeilen sind bereits
    /// weit jenseits dessen, was ein Mensch durchscrollt.
    static let maximumLines = 200_000

    /// Loest den konfigurierten Wert auf. `nil` (Schluessel nicht gesetzt) und
    /// jeder Wert ausserhalb der Grenzen fallen auf sinnvolle Werte zurueck —
    /// eine kaputte Preference darf einen Chat nie unbrauchbar machen.
    static func resolve(configured: Int?) -> Int {
        guard let configured else { return defaultLines }
        if configured <= 0 { return defaultLines }
        return min(max(configured, minimumLines), maximumLines)
    }

    /// Der Scrollbar-Knob ist proportional zum sichtbaren Anteil
    /// (`rows / lines.count`) und wird bei grossem Scrollback rechnerisch
    /// winzig; SwiftTerm deckelt ihn bei 1 %. Das ist der bewusst in Kauf
    /// genommene Preis fuer den langen Puffer.
    static func expectedThumbFraction(rows: Int, scrollbackLines: Int) -> Double {
        guard rows > 0 else { return 1 }
        let total = Double(rows + scrollbackLines)
        return max(Double(rows) / total, 0.01)
    }
}

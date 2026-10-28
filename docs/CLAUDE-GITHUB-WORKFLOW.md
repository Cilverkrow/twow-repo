# Claude ↔ GitHub ↔ Spiel: Arbeitsablauf

Stand 28.10.2026. Das Bild zeigt, wie die Claude-Chats über GitHub zusammenarbeiten
und wie ein Fix vom Befund im Spiel bis auf den Live-Server kommt.
Maßgeblich bleiben das lokale Arbeits-Overlay (AGENTS.md, Ä12–Ä17) und ADR-0031.

## Gesamtablauf

```mermaid
flowchart TD
    subgraph SPIEL["Spiel (Server und Bots)"]
        LIVE["Live-Server<br/>Roster-Bots"]
        TEST["Test-Realms A / B / C<br/>+ zweiter Test-PC"]
    end

    subgraph STEUERUNG["Steuerung"]
        OWNER(["Inhaber"])
        OB00["OB-00 Leitstand<br/>Priorität, Entscheide, Lagebericht"]
    end

    subgraph FACH["Fach-Chats (Claude Code)"]
        CLI["Fach-CLIs (Auswahl): CLI-Deep · CLI-ROT<br/>CLI-PATH · CLI-GRP · CLI-Berufe<br/>sowie OB-15/20/50/60"]
        OB40["OB-40 Daten<br/>Roster, Test-DBs, Resets"]
        OB30["OB-30 Plattform<br/>Queue, Pins, Images, Tests"]
        OB10["OB-10 Review<br/>einziger Merge-Reviewer"]
    end

    subgraph GH["GitHub"]
        ISSUE["Issue<br/>Body = Vertrag<br/>Kommentare = Evidenz"]
        PR["PR-Zwillinge twow-core<br/>release/9.x + main"]
        CI["CI Debian trixie<br/>Build + ctest + Contracts"]
        LANE["Merge-Lane<br/>nur Paare, exakte Heads"]
        PIN["Pin-PR twow-repo<br/>Core-sha → Image"]
        GHCR["ghcr Image<br/>build once / promote"]
    end

    LIVE -- "Befund: Log, Messung, Inhaber-Beobachtung" --> OB00
    TEST -- "RESULT, CAUSE.md, Census" --> CLI
    OWNER -- "Ziele, Einzelfreigaben" --> OB00
    OB00 -- "Auftrag + Priorität" --> CLI
    OB00 --> ISSUE
    CLI -- "Ursache offline belegt<br/>(Action-Logs zuerst)" --> ISSUE
    CLI -- "Fix hinter Schalter,<br/>Contracts lokal grün" --> PR
    PR --> CI
    CI -- grün --> OB10
    OB10 -- "OK merge #rel @head #main @head" --> LANE
    LANE -- "Merge (Ä16: grün = frei)" --> PIN
    PIN --> GHCR
    GHCR --> OB30
    OB40 -- "Roster-Zustand, Resets" --> OB30
    CLI -- "PREREG + Kit" --> OB30
    OB30 -- "Prioritäts-Queue,<br/>Gates, Batch-Verify" --> TEST
    CLI -- "Auswertung → Empfehlung" --> OB00
    OB00 -- "ADOPT → Profil / Live-Paket" --> OWNER
    OWNER -- "Zug-Auftrag, Live nach Betriebsplan<br/>+ DB-Einzelfreigaben" --> LIVE
```

## Ein Fix im Detail

```mermaid
sequenceDiagram
    autonumber
    actor Inhaber
    participant OB00 as OB-00
    participant CLI as Fach-CLI
    participant GH as GitHub (PR + CI)
    participant OB10 as OB-10
    participant OB30 as OB-30
    participant Test as Test-Realm
    participant Live as Live

    Inhaber->>OB00: Ziel oder Beobachtung
    OB00->>CLI: Auftrag, Priorität
    CLI->>CLI: Ursache offline aus Logs (CAUSE.md)
    CLI->>GH: PR-Paar non-draft (neue Verhaltensänderung hinter Schalter)
    GH-->>CLI: CI trixie grün
    CLI->>OB00: Heads
    OB00->>OB10: Review-Queue-Zeile
    OB10->>GH: OK merge #rel @head #main @head
    GH->>GH: Lane merged das Paar
    OB30->>GH: Pin-PR, Image auf ghcr
    CLI->>OB30: PREREG + Kit (A/B im selben Realm)
    OB30->>Test: Queue-Slot, Reset, Verify, MEAS
    Test-->>CLI: Daten je Kohorte
    CLI->>OB00: RESULT (ADOPT / HARM / NOT MET)
    alt ADOPT
        OB00->>Inhaber: Live-Paket-Vorschlag
        Inhaber->>Live: Zug-Auftrag, DB-Einzelfreigaben (Live an/aus nach Betriebsplan)
    else HARM / NOT MET
        OB00->>CLI: Ursache weiter suchen, neuer Fix
    end
```

## Regeln in einem Satz

- Neue Verhaltensänderungen mit offenem Nutzen kommen hinter Schaltern (Default 0) und gehen erst nach einem A/B-Nachweis ins Profil; angenommene Bug-Fixes laufen mit Default 1 (z. B. #752, #756).
- Merge nur bei grüner CI und OB-10-OK auf den exakten Heads; twow-core-PRs als Zwillingspaar (release/x.x + main), twow-repo-PRs einzeln.
- Images werden nur in CI gebaut; lokal laufen in der Regel nur TU-Compiles und Contracts.
- Live an/aus nach Betriebsplan und Deploy im erteilten Zug-Auftrag sind Dauerfreigaben (Ä16); Live-DB-Mutation, Löschen, Secrets und Spielentscheidungen brauchen eine Einzelfreigabe des Inhabers (Weitergabe nach Ä13).

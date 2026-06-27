---
description: Struktur und Konventionen der Commit-Dokumentation
description_long: |
  Erklärt den Aufbau des commit-doc-Verzeichnisses, die globale INDEX.md
  und das Format der einzelnen COMMIT.md-Dateien pro Commit oder WIP-Stand.
updated: 2026-06-27 14:10
---

# Commit-Dokumentation

Dieses Verzeichnis dokumentiert einzelne Commits und WIP-Stände des Projekts.

## Struktur

```
docs/commit-doc/
├── README.md                     # Diese Datei
├── INDEX.md                      # GLOBALE Index aller Commits/WIPs (PFLICHT pflegen!)
│
└── [hash-oder-wip-name]/         # Ein Ordner pro dokumentierter Änderung
    └── COMMIT.md                 # Detail-Dokumentation
```

## Konventionen

- **Ein Ordner pro Änderung**: `[hash]-[kurzname]` für Commits, `wip-[kurzname]` für WIP-Stände.
- **INDEX.md ist Pflicht**: Jede neue Dokumentation bekommt eine Zeile in `INDEX.md`.
- **YAML-Frontmatter**: Jede `.md` startet mit `description`, `description_long`, `updated`.
- **Sprache**: Deutsch, echte Umlaute (ä/ö/ü), Code-Kommentare Englisch.

## Verwandte Feature-Dokumentation

Tiefergehende Architektur-Beschreibungen leben unter `docs/features/[feature]/`.
Die COMMIT.md verlinkt dorthin, statt Architektur doppelt zu pflegen.

# SQLite Migration Design

Replace Grist as the data source with a SQLite database committed to the repository.

## Overview

The JSON cache files remain the interface between the data layer and the application - only the source changes.

```
Before:  npm run build -> fetch Grist API -> write JSON -> next build
After:   npm run build -> read SQLite    -> write JSON -> next build
```

### Goals

- Remove Grist as an external dependency
- Enable deployment without API credentials
- Keep all application code unchanged (pages, components, types)
- Maintain current build/deploy workflow
- Output **identical** JSON files to current Grist-based output

### Non-goals (future work)

- Schema cleanup (proper types, normalized foreign keys)
- Admin UI for content editing
- Removing JSON cache layer
- Fixing TypeScript types (unused `key` field in labels, `en` field in texts)

## Files Affected

| File | Change |
|------|--------|
| `src/lib/cacheDownloader.ts` | Rewrite to read SQLite |
| `src/lib/requests/` | Delete entire directory |
| `src/scripts/downloadCacheData.ts` | Update imports |
| `.env.example` | Remove Grist variables |
| `.github/workflows/ci.yml` | Remove Grist secrets |
| `package.json` | Add `better-sqlite3`, remove unused deps |
| `data/hilf-mir.db` | New SQLite database file |

## Database Schema

Schema derived from **current JSON output** (not Grist export). Three tables:

```sql
-- Texts: key-value pairs for UI strings
-- JSON output: { "siteTitle": "...", "homeWelcomeText": "...", ... }
CREATE TABLE texts (
  key TEXT PRIMARY KEY,
  de TEXT NOT NULL
);

-- Labels: filter tags
-- JSON output: [{ id: 1, fields: { text, icon, group2, order } }, ...]
CREATE TABLE labels (
  id INTEGER PRIMARY KEY,
  text TEXT,
  icon TEXT,
  group2 TEXT,
  "order" INTEGER
);

-- Records: facilities
-- JSON output: [{ id: 5, fields: { Einrichtung, Schlagworte, ... } }, ...]
CREATE TABLE records (
  id INTEGER PRIMARY KEY,
  ID2 TEXT,
  Einrichtung TEXT,
  Trager TEXT,
  Anzeigen INTEGER DEFAULT 1,
  Typ TEXT,
  Schlagworte TEXT,  -- JSON array: '["L",3,5,20]' - MUST preserve "L"
  Zielgruppe TEXT,
  Beratungsmoglichkeiten TEXT,
  Prio TEXT,
  Sprachen TEXT,
  Barrierefreiheit TEXT,
  Kategorie TEXT,
  Uber_uns TEXT,
  Strasse TEXT,
  Hausnummer TEXT,
  Zusatz TEXT,
  PLZ INTEGER,
  Bezirk TEXT,
  Stadtteil TEXT,
  Telefonnummer TEXT,
  EMail TEXT,
  Website TEXT,
  c24_h_7_Tage TEXT,
  Montag TEXT,
  Dienstag TEXT,
  Mittwoch TEXT,
  Donnerstag TEXT,
  Freitag TEXT,
  Samstag TEXT,
  Sonntag TEXT,
  Art_der_Anmeldung TEXT,
  Weitere_Offnungszeiten TEXT,
  lat TEXT,
  long TEXT,
  Ready INTEGER DEFAULT 0
);
```

### Schema Notes

- **Derived from JSON output**, not Grist internal schema
- Column names match JSON field names exactly
- No `en` column in texts (not used in app)
- No `key` column in labels (not used in app)

### Relationships

**`records.Schlagworte` → `labels.id`** (many-to-many)

The only foreign key relationship in the data. `Schlagworte` contains an array of label IDs:
```
records.Schlagworte = ["L", 3, 5, 20]  →  labels.id IN (3, 5, 20)
```

The "L" is a Grist type marker for reference lists, not actual data.

Other fields that look like they could be references are actually plain text:
- `Typ`: Enum text ("Amt", "Beratung", "Klinik", "Online", "Selbsthilfe")
- `Prio`: Enum text ("Hoch", "Mittel", "Niedrig", "Versteckt")
- `Zielgruppe`: Comma-separated text (not referencing Labels)
- `Bezirk`, `Kategorie`: Plain text

Note: TypeScript type for `Prio` has typo "Niedrieg" instead of "Niedrig".

### The "L" in Schlagworte

Grist uses `["L", 3, 5, 20]` format for reference lists. The "L" is a type marker meaning "List".

The app handles this gracefully in `useRecordLabels.ts`:
```typescript
const recordLabels = labels
  .map((lId) => filters.find((l) => l.id === lId))  // "L" finds no match
  .filter(Boolean)  // undefined filtered out
```

**We MUST preserve the "L"** to maintain exact JSON compatibility.

## Implementation Steps

### Step 1: Create SQLite from current JSON

Create `src/scripts/createDatabaseFromJson.ts`:

1. Read current JSON files (just downloaded from Grist)
2. Create SQLite database with schema above
3. Transform and insert data:
   - `texts.json` (key-value map) → `texts` table rows
   - `labels.json` (array of `{id, fields}`) → `labels` table rows
   - `records.json` (array of `{id, fields}`) → `records` table rows
   - Stringify `Schlagworte` arrays back to JSON
4. Save to `data/hilf-mir.db`

Run once after downloading current Grist data.

### Step 2: Add SQLite dependency

```bash
npm install --save-exact better-sqlite3
npm install --save-exact --save-dev @types/better-sqlite3
```

### Step 3: Rewrite cacheDownloader.ts

Read from SQLite, output identical JSON:

```typescript
import Database from 'better-sqlite3'

export async function downloadCacheData(): Promise<void> {
  const db = new Database('data/hilf-mir.db', { readonly: true })

  // Texts: rows → key-value map
  const textsRows = db.prepare('SELECT key, de FROM texts').all()
  const texts = Object.fromEntries(textsRows.map(r => [r.key, r.de]))

  // Labels: rows → array of { id, fields: {...} }
  const labelsRows = db.prepare('SELECT * FROM labels').all()
  const labels = labelsRows.map(row => ({
    id: row.id,
    fields: {
      text: row.text,
      icon: row.icon,
      group2: row.group2,
      order: row.order
    }
  }))

  // Records: rows → array of { id, fields: {...} }
  const recordsRows = db.prepare('SELECT * FROM records WHERE Anzeigen = 1').all()
  const records = recordsRows.map(row => ({
    id: row.id,
    fields: {
      ...row,
      Schlagworte: JSON.parse(row.Schlagworte || '[]')
    }
  }))

  db.close()

  await writeJsonFile('data/texts.json', texts)
  await writeJsonFile('data/records.json', records)
  await writeJsonFile('data/labels.json', labels)
}
```

### Step 4: Delete Grist code

Remove:
- `src/lib/requests/getGristTableData.ts`
- `src/lib/requests/getGristRecords.ts`
- `src/lib/requests/getGristLabels.ts`
- `src/lib/requests/getGristTexts.ts`

### Step 5: Update configuration

Remove from `.env.example`:
```
NEXT_SECRET_GRIST_DOMAIN
NEXT_SECRET_GRIST_DOC_ID
NEXT_SECRET_GRIST_RECORDS_TABLE
NEXT_SECRET_GRIST_LABELS_TABLE
NEXT_SECRET_GRIST_TEXTS_TABLE
NEXT_SECRET_GRIST_API_KEY
```

Remove Grist secrets from `.github/workflows/ci.yml`.

### Step 6: Update .gitignore

Ensure `data/hilf-mir.db` is NOT gitignored (it should be committed).
Keep `data/*.json` gitignored (generated at build time).

### Step 7: Verify

1. Run `npm run build` - should generate JSON from SQLite
2. Compare generated JSON with original: `diff data/records.json data/records.json.bak`
3. Run `npm run dev` - verify app works identically
4. Run tests
5. Deploy to staging

## Data Management

Content updates are made by editing the SQLite database directly using tools like:
- DB Browser for SQLite (GUI)
- TablePlus
- SQLite CLI

Workflow:
1. Edit `data/hilf-mir.db`
2. Commit changes
3. Deploy (build regenerates JSON from updated SQLite)

## Future Improvements

These are explicitly out of scope for this migration but documented for later:

### After first verified build

1. **Remove "L" from Schlagworte**: The "L" is a Grist reference list marker, not actual data. The app filters it out implicitly. Safe to remove once build is verified.

### Later

2. **Normalize Schlagworte**: Replace JSON array with proper junction table `records_labels(record_id, label_id)`. Requires app code changes.
3. **Schema cleanup**: Proper data types (`lat`/`long` as REAL), foreign key constraints
4. **Remove JSON layer**: Have app read directly from SQLite
5. **Admin UI**: Web interface for non-technical content editors
6. **Validation**: Add constraints and data validation at the database level
7. **Fix TypeScript types**: Remove unused `key` field from `GristLabelType`, `en` from texts
8. **Data cleanup**: Fix dirty data like `"Beratung\n"` in Typ field

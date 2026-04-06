# Recherche-Plan: Falsche Disk-Kapazität bei Disconnect

## Problem
Eine 2TB Drive zeigt korrekte Werte wenn gemountet. Sobald abgesteckt, springt die Anzeige auf **994,66 GB** und **337,05 GB frei**. Das sind die Werte der **Boot-Disk** (Macintosh HD), nicht der externen Drive.

## Hypothese
Irgendwo wird `statvfs` oder `DiskSpace.read()` auf einen Pfad aufgerufen der nach dem Unmount auf das Root-Filesystem fällt (z.B. `/Volumes` statt `/Volumes/MyDrive`), oder ein mount_path wird aufgelöst der nicht mehr existiert und macOS gibt die Root-Partition zurück.

---

## Phase 1: Daten sammeln

### 1.1 Boot-Disk Werte verifizieren
```bash
# Prüfe ob 994,66 GB = Boot-Disk
python3 -c "
import os
stat = os.statvfs('/')
total = stat.f_frsize * stat.f_blocks
free = stat.f_frsize * stat.f_bavail
print(f'Boot: {total/1e9:.2f} GB total, {free/1e9:.2f} GB free')

stat2 = os.statvfs('/Volumes')
total2 = stat2.f_frsize * stat2.f_blocks
free2 = stat2.f_frsize * stat2.f_bavail
print(f'/Volumes: {total2/1e9:.2f} GB total, {free2/1e9:.2f} GB free')
"
```
**Erwartung**: Einer dieser Werte ist 994,66 GB / 337,05 GB → bestätigt Hypothese.

### 1.2 DB-Werte prüfen
```bash
python3 -c "
import sqlite3
conn = sqlite3.connect('~/.drivecatalog/catalog.db')
conn.row_factory = sqlite3.Row
for r in conn.execute('SELECT name, total_bytes, used_bytes, mount_path FROM drives').fetchall():
    t = (r['total_bytes'] or 0) / 1e9
    u = (r['used_bytes'] or 0) / 1e9 if r['used_bytes'] else 'NULL'
    print(f\"{r['name']}: total={t:.2f}GB, used={u}, mount={r['mount_path']}\")
"
```
**Prüfe**: Welche Drive hat total_bytes ≈ 994,66 GB? Hat die 2TB Drive korrekte Werte in der DB?

### 1.3 API-Response prüfen
```bash
# Mounted:
curl -s http://localhost:8101/drives | python3 -c "
import json, sys
for d in json.load(sys.stdin)['drives']:
    t = d['total_bytes']/1e9
    u = (d.get('used_bytes') or 0)/1e9
    print(f\"{d['name']}: total={t:.2f}GB, used={u:.2f}GB, mount={d['mount_path']}\")
"
# Dann Drive abstecken und nochmal aufrufen
```

---

## Phase 2: Code-Pfade tracen

### 2.1 Alle Stellen die `statvfs` oder `DiskSpace.read` aufrufen

Suche JEDEN Ort im gesamten Codebase wo Disk-Space gelesen wird:

```
Grep: os.statvfs|DiskSpace\.read|attributesOfFileSystem|systemSize|systemFreeSize
```

Für JEDE Stelle prüfen:
- Welcher Pfad wird übergeben?
- Was passiert wenn der Pfad nicht existiert?
- Fällt der Pfad auf `/` oder `/Volumes` zurück?

### 2.2 `GET /drives` Endpoint im Detail

`src/drivecatalog/api/routes/drives.py` Zeile 49-77:
- Für jede Drive: `Path(mp).exists()` → wenn True: `os.statvfs(mp)`
- **KRITISCH**: Was gibt `Path("/Volumes/MyDrive").exists()` zurück DIREKT NACH dem Unmount? Gibt es ein Race Condition wo der Pfad noch kurz existiert aber auf ein anderes Filesystem zeigt?

### 2.3 `loadDrives()` Timing

`DriveCatalog/Views/Drives/DriveListView.swift`:
- `didUnmountNotification` → `loadDrives()` → `GET /drives`
- Race: Unmount-Event feuert, aber `/Volumes/MyDrive` existiert noch als leerer Mount-Point für ~100ms
- In diesem Fenster: `os.statvfs("/Volumes/MyDrive")` gibt Boot-Disk-Werte zurück weil der Mount-Point jetzt zum Root-FS gehört

### 2.4 macOS Mount-Point Verhalten

Recherchiere:
- Bleibt `/Volumes/MyDrive` als leerer Ordner nach Unmount kurz bestehen?
- Wenn ja: `statvfs` auf einen leeren Ordner unter `/Volumes/` gibt die Werte des Parent-Filesystems zurück (= Boot-Disk)
- Das wäre der Root Cause

### 2.5 `_update_drive_identifiers` und `recognize_drive`

Beide rufen `get_drive_size(mount_path)` auf → `os.statvfs(path)` → `f_frsize * f_blocks`
- Wenn das auf einem Phantom-Mount-Point aufgerufen wird → Boot-Disk-Werte → **werden in DB geschrieben** → persistiert falsche Werte

### 2.6 ViewCache und SwiftUI State

- `DiskSpace.read(path:)` in SwiftUI → `FileManager.attributesOfFileSystem`
- Wenn der Pfad nicht existiert → nil → gut
- Wenn der Pfad als leerer Ordner existiert → Boot-Disk-Werte → **schlecht**
- Prüfe: Wird `diskSpace` nach Unmount nochmal gesetzt bevor es nil wird?

---

## Phase 3: Reproduzieren

### 3.1 Manueller Test
1. Drive anschließen, App öffnen, Werte notieren (total, used, free)
2. Drive abstecken
3. SOFORT Werte in UI notieren
4. Nach 2 Sekunden nochmal notieren
5. DB-Werte prüfen: `SELECT total_bytes, used_bytes FROM drives WHERE name = 'X'`
6. Stimmen die DB-Werte mit den falschen UI-Werten überein? → Backend schreibt falsche Werte
7. Oder stimmt die DB aber die UI zeigt falsch? → Frontend-Bug

### 3.2 Automatisierter Test
```python
# Test: statvfs auf einen Pfad der gerade ungemountet wurde
import os, time, subprocess

mount_path = "/Volumes/TESTDRIVE"  # Einsetzen

# Vor Unmount
stat_before = os.statvfs(mount_path)
total_before = stat_before.f_frsize * stat_before.f_blocks
print(f"Before unmount: {total_before / 1e9:.2f} GB")

# Unmount
subprocess.run(["diskutil", "unmount", mount_path])

# Sofort danach
for i in range(20):
    try:
        exists = os.path.exists(mount_path)
        if exists:
            stat_after = os.statvfs(mount_path)
            total_after = stat_after.f_frsize * stat_after.f_blocks
            print(f"  {i*100}ms after unmount: exists={exists}, total={total_after / 1e9:.2f} GB")
        else:
            print(f"  {i*100}ms after unmount: path gone")
            break
    except OSError as e:
        print(f"  {i*100}ms after unmount: OSError: {e}")
        break
    time.sleep(0.1)
```

### 3.3 API-Timing-Test
```bash
# Terminal 1: Watch API response
watch -n 0.5 'curl -s http://localhost:8101/drives | python3 -c "import json,sys; [print(f\"{d[\"name\"]}: {d[\"total_bytes\"]/1e9:.2f}GB\") for d in json.load(sys.stdin)[\"drives\"]]"'

# Terminal 2: Abstecken und beobachten wann sich Werte ändern
```

---

## Phase 4: Fix entwickeln

### 4.1 Wenn Root Cause = Race Condition bei statvfs

**Fix**: Bevor `statvfs` aufgerufen wird, prüfe ob der Pfad wirklich zu einem Mount-Point gehört:
```python
def is_real_mount(path: str) -> bool:
    """Check if path is a real mount point, not a leftover directory."""
    if not os.path.exists(path):
        return False
    # statvfs on parent — if same device, it's not a real mount
    try:
        stat_path = os.stat(path)
        stat_parent = os.stat(os.path.dirname(path))
        return stat_path.st_dev != stat_parent.st_dev
    except OSError:
        return False
```
Wenn `st_dev` gleich ist wie der Parent → der Mount-Point ist ein normaler Ordner auf dem Root-FS → **nicht** statvfs aufrufen.

### 4.2 Wenn Root Cause = DB wird mit falschen Werten überschrieben

**Fix**: Vor dem Schreiben in DB prüfen ob der neue total_bytes Wert plausibel ist:
```python
# Nur schreiben wenn der Wert sich nicht drastisch geändert hat
old_total = drive["total_bytes"]
if old_total and abs(new_total - old_total) / old_total > 0.5:
    logger.warning("Rejecting suspicious total_bytes change: %d -> %d", old_total, new_total)
    return  # Don't persist
```

### 4.3 Wenn Root Cause = Frontend-Timing

**Fix**: `diskSpace` auf nil setzen SOFORT wenn Unmount-Notification kommt, BEVOR `loadStatus` oder `loadDrives` aufgerufen wird.

---

## Phase 5: Verifizieren

1. Reproduziere das Problem mit dem alten Code (Phase 3)
2. Wende den Fix an
3. Wiederhole den Test — Werte müssen stabil bleiben nach Disconnect
4. Teste Edge Cases:
   - Drive abstecken während Scan läuft
   - Zwei Drives gleichzeitig abstecken
   - Drive abstecken und sofort wieder anstecken
5. Prüfe dass korrekte Werte beim nächsten Mount wieder live angezeigt werden

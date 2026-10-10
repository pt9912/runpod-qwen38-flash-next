# Startzeiten

Deutsch | [English](startup-times.md) · [← Anleitung](guide.de.md)

Wie lange ein Pod vom Start bis zur ersten Antwort braucht, gemessen auf RunPod mit 1× H200 (Secure Cloud,
`PLE_MMAP=1`) am **2026-10-04** und **2026-10-10**. Jeder Wert ist eine **Einzelbeobachtung** aus den Zeitstempeln
von vLLM selbst oder von `make wait-ready`, nicht wiederholt. Zeiten ab 60 s sind in Minuten angegeben und auf
ganze Sekunden gerundet.

## Überblick

| Variante | Zeit bis bereit | Uhr startet bei | Planen mit | Anmerkung |
|---|---|---|---|---|
| Network Volume, Start 1 (warmer Host) | 5 min 26 s | erster vLLM-Logzeile | 10 bis 16 min (alle drei) | der günstige Fall, vermutlich auf diesem Host zwischengespeicherte Dateien |
| Network Volume, Start 2 (kalter Host) | 15 min 58 s | erster vLLM-Logzeile | 10 bis 16 min (alle drei) | Hauptgewichte brauchten 11 min 14 s |
| Network Volume, Start 3 | 10 min 10 s | erster vLLM-Logzeile | 10 bis 16 min (alle drei) | Hauptgewichte brauchten 8 min 1 s |
| Ohne Volume (`STORAGE=local`), neuer Pod | **13 min 43 s** | `startedAt` des Pods | **etwa 14 min** | Image ziehen etwa 3 min 45 s, Download 5 min 4 s |
| Ohne Volume (`STORAGE=local`), Neustart des gestoppten Pods | **8 min 57 s** | `startedAt` des Pods | **etwa 9 min** | Image schon auf dem Host, Download 4 min 15 s |
| Global Volume | nicht abgeschlossen | | | bei Shard 40 von 133 nach 12 min abgebrochen |

Die Uhren unterscheiden sich: Die ersten drei Starts enthalten nicht das Ziehen des Pod-Images auf den Host und den Start
des Containers (8,67 GB komprimiert, nicht gemessen), die beiden Starts mit `STORAGE=local` schon. Vergleiche sie mit
diesem Vorbehalt.

## Network Volume (2026-10-04, CA-MTL-3, Modell und Caches auf dem Volume)

| | Start 1 (warmer Host) | Start 2 (kalter Host) | Start 3 |
|---|---|---|---|
| Image | `:2` | `:2` (gleiche Pod-Einstellungen) | `:3` |
| Einstellungen | validierter Betrieb | wie Start 1, aber `MAX_MODEL_LEN=262144`, `MAX_NUM_SEQS=6` | wie Start 2 |
| Pod | | neuer Pod auf einem Host, der das Modell nicht gerade gelesen hatte | neuer Pod |
| Erste vLLM-Logzeile bis `Application startup complete` | **5 min 26 s** (08:09:31 bis 08:14:57 UTC) | **15 min 58 s** (08:29:04 bis 08:45:02 UTC) | **10 min 10 s** (09:00:39 bis 09:10:49 UTC) |
| Laden der Hauptgewichte | 1 min 50 s | 11 min 14 s | 8 min 1 s |
| Laden der MTP-Draft-Gewichte | 8,8 s | 1 min 45 s | 12,5 s |
| Modell laden insgesamt (vLLMs eigene Angabe) | 2 min 14 s | 13 min 15 s | nicht abgelesen |
| `torch.compile`, Hauptmodell | 40,6 s | 30 s | 0,76 s |
| `torch.compile`, Draft-Kopf | 8,2 s | 5 s | 4,2 s |
| FlashInfer-Autotune | 10,2 s (0 neue Konfigurationen gespeichert) | nicht abgelesen | nicht abgelesen |
| CUDA-Graphen (Hauptmodell, dann Draft und Prefill) | wenige Sekunden | nicht abgelesen | nicht abgelesen |

- **Nur Start 1:** Der Prewarm der 26,8 GiB großen PLE-Tabelle in den Seiten-Cache begann um 08:11:36 UTC, das Ende wurde nicht
  einzeln geloggt. Die ersten Anfragen hatten ein einmaliges Triton-Kernel-JIT mit etwa 6 s zusätzlicher Latenz (08:17:59 bis
  08:18:05 UTC).
- **Warum die Streuung:** Sie kommt fast ganz vom Lesen der Gewichte vom Volume (1 min 50 s, 11 min 14 s, 8 min 1 s). Die
  Ursache, kaltes Lesen von etwa 100 GiB mit rund 150 MB/s, ist eine Schlussfolgerung, nicht gemessen.
- **Compile-Zeiten von Start 3** sind winzig, weil der Compile-Cache auf dem Volume inzwischen vollständig war. Die Compile-Zeiten
  von Start 1 stammen vom ersten Lauf mit der mmap-Einstellung und enthalten daher vermutlich das Kompilieren.

## Ohne Volume (`STORAGE=local`, Image `:4`)

2026-10-10, 1× H200 in EUR-IS-4, `MAX_MODEL_LEN=262144`, `MAX_NUM_SEQS=6`, 200 GB Container-Disk, `HF_TOKEN`. Das Modell wird bei
jedem Start von Hugging Face auf die Container-Disk geladen.

| Phase | Neuer Pod (`startedAt` 16:03:02 UTC) | Neustart des gestoppten Pods (`startedAt` 16:22:23 UTC) |
|---|---|---|
| `startedAt` bis zur ersten `Prefetch:`-Zeile (Image ziehen und Container starten, nicht einzeln gemessen) | etwa 3 min 45 s | 3 s |
| Download der 109,23 GB von Hugging Face auf die Container-Disk | **5 min 4 s** (16:06:47 bis 16:11:51) | **4 min 15 s** (16:22:26 bis 16:26:41) |
| Prefetch fertig bis zur Engine-Initialisierung von vLLM (Python und vLLM starten) | etwa 52 s | nicht abgelesen |
| Laden der Hauptgewichte von der lokalen Disk | 1 min 28 s | 1 min 29 s |
| Laden der MTP-Draft-Gewichte | 5,7 s | 5,7 s |
| Modell laden insgesamt (Angabe von vLLM) | 1 min 46 s | 1 min 47 s |
| `torch.compile`, Hauptmodell | 23,8 s | 23,5 s |
| `torch.compile`, Draft-Kopf | 3,3 s | 3,3 s |
| FlashInfer-Autotune | etwa 6 s (0 Konfigurationen gespeichert) | nicht abgelesen |
| CUDA-Graphen | etwa 9 s | nicht abgelesen |
| `init engine` von vLLM insgesamt (Profil, KV-Cache, Warm-up) | 1 min 27 s (Kompilieren 27,1 s) | nicht abgelesen |
| `wait-ready`: erste HTTP-200-Antwort (Abfrage alle 15 s) | **13 min 43 s** | **8 min 57 s** |

- **Neustart:** derselbe Pod, 20 Minuten später; seine alte Maschine war noch frei (`make stop`, dann `make pod-start`). Die
  Container-Disk war **nach dem Stoppen leer**, der Entrypoint lud das Modell also erneut herunter, und der Compile-Cache war
  ebenfalls weg.
- **Was ein Neustart spart:** fast 5 Minuten (4 min 46 s) gegenüber dem neuen Pod, und das ist fast ganz das Ziehen des Images: Die
  erste `Prefetch:`-Zeile kam 3 s nach `startedAt` statt nach 3 min 45 s, weil das Image schon auf dem Host lag. Ein Neustart
  spart also das Ziehen, nicht den Download.
- **KV-Cache und Prüfung:** Der KV-Cache fasst 1.690.023 Tokens (Parallelität 6,45 bei 262.144 Tokens). `make check` bestand.

## Global Volume (2026-10-10, 1× H200 in US-NC-1)

| Schritt | Gemessen |
|---|---|
| vLLM lädt die 133 Shards vom Volume: die ersten drei | 25 s, 1 min 7 s und 54 s |
| vLLM lädt die 133 Shards: die folgenden | je 13 bis 18 s; vLLM schätzte für den Rest 24 bis 29 min |
| Ergebnis | **bei Shard 40 nach 12 min abgebrochen**, ein vollständiger Start wurde also nicht gemessen |

## Downloads und Kopien

| Übertragung | Zeit | Anmerkung |
|---|---|---|
| Hugging Face auf ein leeres Network Volume, Download und Laden zusammen | 4 min 7 s | 2026-10-04, CA-MTL-3, ohne mmap, `HF_XET_HIGH_PERFORMANCE=1`; vLLM meldete `Model loading took 102.87 GiB memory and 247.17 seconds`. Dieser Pod scheiterte danach am KV-Cache (siehe Anleitung); es ist also nur eine Messung von Download und Laden, einmal gesehen |
| Hugging Face auf die Container-Disk eines Pods, Befüll-Pod für das Global Volume | 1 min 32 s und 4 min 48 s | 2026-10-10, zwei Läufe, mit `HF_TOKEN` |
| Hugging Face auf die Container-Disk, Serving-Pod, neu | 5 min 4 s | siehe oben |
| Hugging Face auf die Container-Disk, Serving-Pod, Neustart | 4 min 15 s | siehe oben |
| Container-Disk aufs Global Volume (geschrieben, dann Datei für Datei geprüft) | etwa 13 min | 2026-10-10 |

Was aus diesen Zahlen folgt, steht im [Guide](guide.de.md#lokaler-speicher-download-beim-start).

## Grenzen dieser Zahlen

- Jeder Wert ist eine Einzelbeobachtung; die Downloads von Hugging Face schwankten zwischen 1 min 32 s und 5 min 4 s.
- Die ersten drei Starts enthalten nicht das Ziehen des Images und den Start des Containers. Bei den beiden Starts mit
  `STORAGE=local` ist das Ziehen aus `startedAt` bis zur ersten `Prefetch:`-Zeile abgeleitet, nicht einzeln gemessen.
- Nicht gemessen: ein Start mit `STORAGE=local` und warmem Compile-Cache (der Cache geht mit der Container-Disk verloren). Start 3
  oben zeigt, was ein warmer Cache auf dem Network Volume bringt.

## Einen Start selbst messen

Ab dem `startedAt` des Pods:

```bash
make start-when-free ARGS='1200 30' && make wait-ready
```

`wait-ready` fragt `/v1/models` mit deinem Key alle 15 s ab, gezählt ab dem `startedAt` des Pods (über die
API), bis die Antwort 200 kommt, gibt die Zeit aus und hängt sie an `.startup-times.log` an (von git
ignoriert). Führe es zusammen mit dem Start aus; antwortet der Pod schon bei der ersten Abfrage, wird nichts
protokolliert.

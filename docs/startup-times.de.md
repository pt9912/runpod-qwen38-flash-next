# Startzeiten

Deutsch | [English](startup-times.md) · [← Anleitung](guide.de.md)

Werte aus dem Container-Log des validierten Betriebs am **2026-10-04** (1× H200 SXM, Secure Cloud, CA-MTL-3,
Image `:2`, `PLE_MMAP=1`, Modell und Caches schon auf dem Network Volume). Es sind **Einzelbeobachtungen**
aus den Zeitstempeln von vLLM selbst, nicht von den Skripten dieses Repos erzeugt und nicht wiederholt:

| Phase | Zeit |
|---|---|
| Laden der Hauptgewichte | 110,0 s |
| Laden der MTP-Draft-Gewichte | 8,8 s |
| Modell laden insgesamt (vLLMs eigene Angabe) | 133,6 s |
| Prewarm der 26,8 GiB großen PLE-Tabelle in den Seiten-Cache | begann um 08:11:36 UTC; das Ende wurde nicht einzeln geloggt |
| `torch.compile`, Hauptmodell | 40,6 s |
| `torch.compile`, Draft-Kopf | 8,2 s |
| FlashInfer-Autotune | 10,2 s (0 neue Konfigurationen gespeichert) |
| CUDA-Graphen (Hauptmodell, dann Draft und Prefill) | wenige Sekunden |
| **Erste vLLM-Logzeile bis `Application startup complete`** | **5 min 26 s (326 s)**, 08:09:31 bis 08:14:57 UTC |
| Erste Anfragen: einmaliges Triton-Kernel-JIT | etwa 6 s zusätzliche Latenz (08:17:59 bis 08:18:05 UTC) |

**Ein kalter Start, am selben Tag beobachtet** (gleiche Pod-Einstellungen, aber `MAX_MODEL_LEN=262144` und
`MAX_NUM_SEQS=6`, ein neuer Pod auf einem Host, der das Modell nicht gerade gelesen hatte): Von der ersten
vLLM-Logzeile bis `Application startup complete` vergingen **15 min 58 s (958 s)**, 08:29:04 bis 08:45:02 UTC.
Das Laden der Hauptgewichte dauerte **674 s** und das der Draft-Gewichte 105 s (vLLMs Summe für das Laden des
Modells: 795 s), gegenüber 110 s und 9 s in der Tabelle oben; die Compile-Schritte brauchten 30 s und 5 s. Die
Gewichte kommen vom Network Volume, die 5,5 Minuten oben sind also der günstige Fall (vermutlich auf diesem
Host zwischengespeicherte Dateien); plane nach dem Anlegen oder Verschieben eines Pods **eine Viertelstunde**
ein. Die Ursache (kaltes Lesen von etwa 100 GiB mit rund 150 MB/s) ist eine Schlussfolgerung, nicht gemessen.

**Ein dritter Start** (neuer Pod mit Image `:3`, gleiche Einstellungen, 2026-10-04): erste vLLM-Logzeile 09:00:39 bis
`Application startup complete` 09:10:49 UTC, **10 min 10 s (610 s)**. Das Laden der Hauptgewichte dauerte 481 s, das der
Draft-Gewichte 12,5 s; `torch.compile` brauchte nur 0,76 s und 4,2 s, weil der Compile-Cache auf dem Volume inzwischen
vollständig war. Die drei Starts bisher: 5 min 26 s, 15 min 58 s und 10 min 10 s. Die Streuung kommt fast ganz vom Lesen
der Gewichte vom Volume (110 s, 674 s, 481 s); rechne bei einem neuen Pod also mit **10 bis 16 Minuten**.

**Vom Global Volume und von Hugging Face** (2026-10-10, Einzelmessungen, H200 in US-NC-1, `PLE_MMAP=1`):
Das Laden der 133 Shards vom Global Volume dauerte nach einem langsamen Anfang (25, 67 und 54 s für die ersten drei)
je 13 bis 18 s; vLLM schätzte für den Rest 24 bis 29 Minuten. Es wurde **bei Shard 40 nach 12 Minuten abgebrochen**,
ein vollständiger Start wurde also nicht gemessen. Der Download der 109,23 GB von Hugging Face auf die Container-Disk
eines Pods (mit `HF_TOKEN`) dauerte in zwei Läufen **1 min 32 s** und **4 min 48 s**, das Kopieren aufs Global Volume
etwa 13 Minuten. Was daraus folgt, steht im [Guide](guide.de.md#lokaler-speicher-download-beim-start).

**Ohne Volume (`STORAGE=local`, Image `:4`)** (2026-10-10, 1× H200 in EUR-IS-4, `PLE_MMAP=1`,
`MAX_MODEL_LEN=262144`, `MAX_NUM_SEQS=6`, 200 GB Container-Disk, `HF_TOKEN`; **eine Beobachtung**, neuer Pod, alles
kalt). `make wait-ready`: **bereit nach 13 min 43 s (823 s)** ab `startedAt` des Pods (16:03:02 UTC).

| Phase | Zeit |
|---|---|
| `startedAt` bis zur ersten `Prefetch:`-Zeile (Image ziehen und Container starten, nicht einzeln gemessen) | etwa 3 min 45 s (16:03:02 bis 16:06:47) |
| Download der 109,23 GB von Hugging Face auf die Container-Disk | **5 min 04 s** (16:06:47 bis 16:11:51) |
| Prefetch fertig bis zur Engine-Initialisierung von vLLM (Python und vLLM starten) | etwa 52 s (bis 16:12:43) |
| Laden der Hauptgewichte von der lokalen Disk | 88,3 s |
| Laden der MTP-Draft-Gewichte | 5,7 s |
| Modellladen insgesamt (Angabe von vLLM) | 106,4 s |
| `torch.compile`, Hauptmodell und Draft-Kopf (kalter Cache auf einer neuen Container-Disk) | 23,8 s und 3,3 s |
| FlashInfer-Autotune | etwa 6 s (0 Konfigurationen gespeichert) |
| CUDA-Graphen | etwa 9 s |
| `init engine` von vLLM insgesamt (Profil, KV-Cache, Warm-up) | 86,9 s (Kompilieren 27,1 s) |
| `wait-ready`, erste HTTP-200-Antwort (Abfrage alle 15 s) | 823 s nach `startedAt` |

Der KV-Cache fasst 1.690.023 Tokens (Parallelität 6,45 bei 262.144 Tokens). `make check` bestand. Zum Vergleich: Die
drei Starts mit einem Network Volume dauerten 5 min 26 s, 15 min 58 s und 10 min 10 s, und vLLM wurde beim Laden von
einem Global Volume bei Shard 40 von 133 nach 12 Minuten abgebrochen. Jeder Start dieser Variante lädt erneut herunter (die
Container-Disk überlebt den Pod nicht); mit dieser Zahl ist also zu planen: etwa **14 Minuten**, davon etwa 5 für den
Download und etwa 4 für das Ziehen des Images. Die Zeit von Hugging Face schwankte in den früheren Tests zwischen 1,5 und 5
Minuten.

**Neustart des gestoppten Pods** (derselbe Pod, 20 Minuten später, seine alte Maschine war noch frei; `make stop`,
dann `make pod-start`; eine Beobachtung): **bereit nach 8 min 57 s (537 s)** ab dem neuen `startedAt` (16:22:23 UTC).
Die Container-Disk war **nach dem Stoppen leer**: Der Entrypoint lud das Modell erneut herunter (**4 min 15 s**, 16:22:26 bis
16:26:41), danach lud vLLM die Hauptgewichte in 89,1 s (Draft 5,7 s, insgesamt 107,0 s), `torch.compile` brauchte
wieder 23,5 s und 3,3 s (der Compile-Cache war ebenfalls weg). Die knapp 5 Minuten, die der Neustart gegenüber dem ersten
Start (13:43) spart, sind fast ganz das Ziehen des Images: Die erste `Prefetch:`-Zeile kam 3 s nach `startedAt` statt nach
3 min 45 s, weil das Image schon auf dem Host lag. Ein Neustart spart also das Ziehen, nicht den Download.

**Was in diesen Zahlen nicht steckt:** das Ziehen des Pod-Images (8,67 GB komprimiert) auf den Host und der
Start des Containers, das vor der ersten vLLM-Logzeile passiert. Es wurde nicht gemessen: Die Uhr oben
beginnt bei der ersten vLLM-Logzeile, nicht beim `startedAt` des Pods. Ebenfalls nicht gemessen: ein
Neustart eines gestoppten Pods auf seiner alten Maschine und ein Start mit warmem Compile-Cache. Die
Compile-Zeiten oben stammen vom ersten Lauf mit der mmap-Einstellung und enthalten daher vermutlich das
Kompilieren; ein wiederholter Start sollte das meiste davon überspringen.

**Der erste Start eines leeren Volumes** lädt zusätzlich das 109-GB-Modell herunter. Am 2026-10-04 meldete
vLLM in CA-MTL-3 und ohne mmap `Model loading took 102.87 GiB memory and 247.17 seconds` für Download und
Laden zusammen, mit `HF_XET_HIGH_PERFORMANCE=1`. Dieser Pod scheiterte danach am KV-Cache (siehe Anleitung);
es ist also nur eine Messung von Download und Laden, einmal gesehen.

Einen vollständigen Start misst du selbst, ab dem `startedAt` des Pods:

```bash
make start-when-free ARGS='1200 30' && make wait-ready
```

`wait-ready` fragt `/v1/models` mit deinem Key alle 15 s ab, gezählt ab dem `startedAt` des Pods (über die
API), bis die Antwort 200 kommt, gibt die Zeit aus und hängt sie an `.startup-times.log` an (von git
ignoriert). Führe es zusammen mit dem Start aus; antwortet der Pod schon bei der ersten Abfrage, wird nichts
protokolliert.

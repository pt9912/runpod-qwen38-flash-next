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

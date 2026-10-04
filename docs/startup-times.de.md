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

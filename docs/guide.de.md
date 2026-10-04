# runpod-qwen38-flash-next — Anleitung

Deutsch | [English](guide.md) · [← README](../README.md) · [Startzeiten](startup-times.de.md)

Das README enthält den Schnellstart. Diese Anleitung behandelt alles andere: das Setup im Detail, jedes
Skript, die Einstellungen, den Alltag, die Rechnung zu Speicher und Kontext und was schiefgeht und warum.

Alles, was **validiert** heißt, wurde am 2026-10-04 auf einem echten Pod beobachtet (1× H200 SXM, Secure
Cloud, Rechenzentrum CA-MTL-3). Alles andere stammt aus Dokumentation oder ist ungetestet und sagt das.

## Inhalt

1. [Architektur](#architektur)
2. [Die Skripte im Überblick](#die-skripte-im-überblick)
3. [Secrets](#secrets)
4. [Ersteinrichtung](#ersteinrichtung)
5. [Einstellungen (`.env`)](#einstellungen-env)
6. [Network Volume](#network-volume)
7. [Anlegen, prüfen, testen](#anlegen-prüfen-testen)
8. [Alltag: starten, stoppen, löschen](#alltag-starten-stoppen-löschen)
9. [Logs und Fehlersuche](#logs-und-fehlersuche)
10. [Speicher, Kontext und Parallelität](#speicher-kontext-und-parallelität)
11. [GPUs und was validiert wurde](#gpus-und-was-validiert-wurde)
12. [Claude Code](#claude-code)
13. [Der Pod-Pool](#der-pod-pool)
14. [Eigenes Image bauen](#eigenes-image-bauen)

## Architektur

```
dein Rechner                         RunPod                         Docker Hub
────────────                         ──────                         ──────────
make <Ziel>  ──docker run──►  scripts/*.sh  ──REST v2──►  api.runpod.io/v2
(Tools-Image: bash+curl+python3)                            │
                                                            ▼ legt an / startet / stoppt
                                                 Pod (Secure Cloud, 1 GPU)
                                                 ├─ Image  pt9912/vllm-qwen38-b200 ◄── von Docker Hub gezogen
                                                 ├─ /workspace = Network Volume (Modell 109 GB, Caches)
                                                 └─ Port 8000/http  ──►  https://<pod>-8000.proxy.runpod.net
```

- **Tools-Image** (`Dockerfile`): Alpine mit nur bash, curl und python3. Es spricht mit der RunPod-REST-API
  **v2** (`https://api.runpod.io/v2`, überschreibbar mit `RUNPOD_BASE_URL`). vLLM läuft darin nie.
- **Pod-Image** (`image/`): das vLLM-Basisimage plus fünf Patches aus dem Upstream-Rezept, mit
  `serve-b200` als Entrypoint. Der Pod setzt **keinen Befehl**: Der Entrypoint baut die `vllm serve`-Zeile
  aus Umgebungsvariablen (`MODEL`, `CTX`, `TP`, `SEQS`, `MMAP`, ...). `verify-pod.sh` schlägt fehl, wenn
  ein `cmd` überschrieben wurde.
- **Network Volume:** hält das 109,23 GB große Modell unter `/workspace/huggingface` und die Compile- und
  Autotune-Caches unter `/workspace/vllm-cache`. Es überlebt Stopp und Löschen des Pods und ist an ein
  Rechenzentrum gebunden: **Ein Pod muss im Rechenzentrum des Volumes laufen**, und dort muss eine GPU
  frei sein.
- **Endpunkt:** vLLM auf Port 8000, geschützt durch `VLLM_API_KEY`, erreichbar über den RunPod-HTTPS-Proxy.
  Er bedient die OpenAI-API (`/v1/chat/completions`, `/v1/models`) und die Anthropic-API (`/v1/messages`,
  `/v1/messages/count_tokens`). Nur `/v1/*` braucht den Key; `/health`, `/metrics` und `/docs` sind bei
  vLLM absichtlich offen.

## Die Skripte im Überblick

Alles läuft über `make`; es baut zuerst das Tools-Image und bindet `.env` schreibgeschützt ein. Weitere
Argumente stehen in `ARGS`. Ein Name mit Leerzeichen braucht innere Anführungszeichen:
`make gpu ARGS='"RTX PRO 6000"'`.

| Ziel | Skript | Was es tut | Kostet? |
|---|---|---|---|
| `make help` | – | listet alle Ziele | nein |
| `make precheck` | `pre-check.sh` | Werkzeuge, `.env`, Volume-ID; `ARGS=--online` ergänzt einen API-Aufruf | nein |
| `make smoke` | `v2-smoke.sh` | kurzer Lesetest der v2-API (`GET /pods`) | nein |
| `make gpu` | `gpu-availability.sh` | Bestand einer GPU, gesamt und je Rechenzentrum; Exit 2 = keiner (make endet trotzdem mit 0) | nein |
| `make wait-gpu` | `wait-for-gpu.sh` | fragt den Bestand ab, bis die GPU frei ist; startet nichts | nein |
| `make volume` | `create-volume.sh` | `--list`, oder Network Volume anlegen (Trockenlauf ohne `--yes`) | **Volume** |
| `make create` | `create-pod.sh` | Pod anlegen (Trockenlauf ohne `ARGS=--yes`) | **GPU** |
| `make verify` | `verify-pod.sh` | prüft GPU, Volume, Ports, Env gegen `.env` | nein |
| `make check` | `check-endpoint.sh` | Key-Schutz, Modell, Kontextlänge | nein |
| `make logs` | `pod-logs.sh` | Container- und System-Logs live (Strg-C beendet) | nein |
| `make wait-ready` | `wait-for-ready.sh` | wartet, bis vLLM antwortet, loggt die Startzeit | nein |
| `make stop` | `stop-any.sh` | stoppt jeden aktiven Pool-Pod | beendet GPU-Kosten |
| `make pod-stop` | `pod-stop.sh` | stoppt den Pod `RUNPOD_POD_ID` | beendet GPU-Kosten |
| `make pod-terminate` | `pod-terminate.sh` | löscht einen Pod endgültig (`ARGS='--yes [ID]'`) | beendet ihn |
| `make start` | `start-any.sh` | startet einen gestoppten Pool-Pod, sonst legt es einen an | **GPU** |
| `make pod-start` | `pod-start.sh` | startet den gestoppten Pod `RUNPOD_POD_ID` | **GPU** |
| `make start-when-free` | `start-when-free.sh` | wiederholt `pod-start`, solange dessen GPU belegt ist | **GPU** |
| `make abort` | – | stoppt einen hängenden create/start-Container | nein |
| – | `claude-qwen.sh` | startet Claude Code gegen den Pod (auf deinem Rechner, nicht über make) | nein |

Jedes Ziel, das etwas anlegen oder ändern könnte, ist standardmäßig ein Trockenlauf oder verlangt `--yes`.
`make` selbst endet nur mit 0 oder 2; der echte Exit-Code des Skripts steht in `.make-exit-code.<Ziel>`
(von git ignoriert). `make gpu` ist die Ausnahme: „kein Bestand“ (Skript-Exit 2) ist eine Antwort, make
endet also mit 0, und der echte Code landet trotzdem in `.make-exit-code.gpu`.

## Secrets

| Secret | Wo | Wofür |
|---|---|---|
| `RUNPOD_API_KEY` | `.env` | alle Skripte. Lesen geht mit einem Nur-Lese-Key; Anlegen, Starten, Stoppen und Löschen brauchen Schreibrecht auf Pods (sonst HTTP 403) |
| `VLLM_API_KEY` | `.env` **und** ein RunPod-Secret gleichen Namens | der Key, den vLLM erzwingt; Skripte und Claude Code senden ihn |
| `HF_TOKEN` | nur RunPod-Secret | wird bei `--online` eingesetzt, für den Modell-Download |

Der Pod verweist auf die RunPod-Secrets als `{{ RUNPOD_SECRET_<Name> }}`; kein Secret-Wert landet je in der
Pod-Definition oder wird ausgegeben. `verify-pod.sh` schlägt fehl, wenn `VLLM_API_KEY` ein Klartextwert statt
einer Secret-Referenz ist. Fehlt ein Secret, bleibt der Platzhalter unaufgelöst: Bei `VLLM_API_KEY` meldet
`make check` dann 401 mit deinem Key; beim `HF_TOKEN` ist zu erwarten, dass der Download abgelehnt wird
(nicht getestet). `.env` ist von git ignoriert und gehört nie ins Repo.

## Ersteinrichtung

1. `cp .env.example .env`, dann `RUNPOD_API_KEY` und `VLLM_API_KEY` setzen. Die Zeile `REMOTE_IMAGE` zeigt
   schon auf das veröffentlichte Image.
2. Im RunPod-Console die Secrets `VLLM_API_KEY` (gleicher Wert) und `HF_TOKEN` anlegen.
3. `make precheck ARGS=--online` und `make smoke`: Werkzeuge, `.env` und API-Key.
4. GPU finden: `make gpu ARGS='"NVIDIA H200"'` (oder die gewünschte Karte). Ein Rechenzentrum merken, das
   Bestand hat **und** Network Volumes anbietet.
5. Dort das Volume anlegen: `make volume ARGS='--dc <DC>'` (Trockenlauf), dann `--yes`. Die ausgegebene ID
   als `NETWORK_VOLUME_ID` in `.env` eintragen.
6. `GPU_ID`, `GPU_COUNT=1` und die übrigen Einstellungen unten setzen.
7. Erster Start auf einem leeren Volume: `make create` (Trockenlauf), dann `make create ARGS='--yes --online'`.
   Das Modell wird aufs Volume geladen. Dazu `make logs` beobachten.
8. Nach dem ersten Start auf die Offline-Einstellungen umstellen (`PLE_MMAP=1` mit dem lokalen Modellpfad,
   siehe „Einstellungen“) und für spätere Pods `make create ARGS=--yes` nutzen.

## Einstellungen (`.env`)

Alles optional, wenn nicht anders markiert. Ein in der Shell exportierter Wert schlägt denselben Namen in `.env`.

| Variable | Standard | Bedeutung |
|---|---|---|
| `RUNPOD_API_KEY` | – (nötig) | RunPod-API-Key |
| `VLLM_API_KEY` | – (nötig) | Key, den vLLM erzwingt; gleicher Wert wie das RunPod-Secret |
| `NETWORK_VOLUME_ID` | – (nötig zum Anlegen) | ID deines Network Volumes |
| `REMOTE_IMAGE` | – (nötig zum Anlegen) | Pod-Image, am besten per Digest. Das arm64/sm121-Image der DGX Spark wird abgewiesen |
| `RUNPOD_POD_ID` | – | Ausweich-Pod für Einzel-Pod-Skripte; der aktive Pool-Pod gewinnt |
| `QWEN_URL` | – | Endpunkt-URL, wenn kein Pod aufgelöst wird (Claude Code, `wait-ready`) |
| `GPU_ID` | `NVIDIA B200` | exakte ID aus `make gpu`. In `.env` in Anführungszeichen, wenn sie Leerzeichen hat |
| `GPU_COUNT` | `1` | GPUs je Pod; setzt TP. **Bei 1 bleiben** (siehe GPUs) |
| `DATACENTER` | Rechenzentrum des Volumes | wo der Pod laufen soll |
| `CONTAINER_DISK_GB` | `50` | Container-Disk (das Image hat entpackt etwa 20 GB) |
| `MODEL` | `starkweatherdigital/qwen3.8-flash-next-nvfp4` | HF-ID oder lokales Verzeichnis (nötig bei `PLE_MMAP=1`) |
| `MAX_MODEL_LEN` | `131072` | Kontext je Anfrage; die Grenze des Modells ist 262144 |
| `YARN_FACTOR` | – | statischer YaRN-Faktor (`4.0` bis 1M, `2.0` für 524288), um über 262144 hinauszugehen; braucht `MAX_MODEL_LEN` über 262144 und höchstens 262144 × Faktor. **Ungetestet.** Braucht ein Image mit dieser Änderung (ältere Tags ignorieren sie) |
| `MAX_NUM_SEQS` | `16` | gleichzeitige Sequenzen (1 bis 256) |
| `GPU_MEMORY_UTILIZATION` | `0.90` | Anteil des GPU-Speichers für vLLM |
| `PLE_MMAP` | `0` | `1` liest die 26,8 GiB große PLE-Tabelle von der Platte; **nötig bei 141 GB oder weniger** |
| `VLLM_EXTRA_ARGS` | – | zusätzliche `vllm serve`-Argumente, an Leerzeichen getrennt, ganz am Ende angehängt |
| `POOL_PREFIX` / `POOL_MAX` | `qwen3.8-flash-next` / `6` | der Pod-Pool, siehe unten |
| `VOLUME_NAME` / `VOLUME_SIZE_GB` | `qwen3.8-flash-next` / `150` | Standardwerte von `make volume` |

**Die validierte H200-Einstellung** (Volume in CA-MTL-3):

```
GPU_ID="NVIDIA H200"
GPU_COUNT=1
PLE_MMAP=1
MODEL=/workspace/huggingface/hub/models--starkweatherdigital--qwen3.8-flash-next-nvfp4/snapshots/1b304e5f99de0faaf43c3a959f2b4000294bf65c
```

Das Snapshot-Verzeichnis ist die Hugging-Face-Revision des Modells (`main` war am 2026-10-04 `1b304e5f…`).
Ändert sich die Revision, gibt es den Pfad nicht mehr: Die Verzeichnisse unter
`/workspace/huggingface/hub/models--…/snapshots/` auf dem Volume zeigen die aktuelle. Pod-Einstellungen
stehen beim Anlegen fest; um eine zu ändern, den Pod löschen und neu anlegen.

## Network Volume

- **Größe:** 150 GB sind das empfohlene Minimum: Das Modell hat 109,23 GB (146 Dateien, auf Hugging Face
  gemessen; `du` auf dem Volume zeigte 102 GiB) plus einige GB Caches. 200 GB lassen Platz für eine zweite
  Modellrevision. Ein Volume lässt sich nur **vergrößern**, nie verkleinern, und nicht in ein anderes
  Rechenzentrum verschieben.
- **Preis:** etwa 0,07 $/GB und Monat (Standard-Typ, unter 1 TB; der veröffentlichte Satz von RunPod),
  stündlich abgerechnet, auch wenn kein Pod läuft. 150 GB kosten etwa 10,50 $ im Monat.
- **Anlegen:** `make volume ARGS='--dc <DC>'` ist ein Trockenlauf und zeigt Request und Kosten; mit `--yes`
  wird angelegt. Es prüft, ob das Rechenzentrum existiert und den Typ anbietet, und lehnt ein zweites Volume
  gleichen Namens ab. Nicht jedes Rechenzentrum bietet Volumes an (am 2026-10-04 taten es EUR-IS-4,
  EUR-IS-5, US-GA-2 und US-NC-1 nicht; US-CA-2 bot nur den High-Performance-Typ). `make volume ARGS=--list`
  zeigt deine Volumes.
- **Löschen:** bewusst nicht in diesem Repo. Dafür die RunPod-Console nutzen. Ein Volume kostet, bis es
  gelöscht ist.
- **Ein Pod gleichzeitig:** Zwei Pods mit demselben Volume teilen sich `/workspace/vllm-cache`; die
  Pool-Schutzmechanismen lehnen einen zweiten aktiven Pool-Pod ab.

## Anlegen, prüfen, testen

```bash
make create                        # Trockenlauf: zeigt Request und Bestand, legt nichts an
make create ARGS='--yes'           # legt den Pod an; die GPU-Abrechnung beginnt sofort
make create ARGS='--yes --online'  # dasselbe, mit erlaubten Downloads (erster Start auf leerem Volume)
```

Optionen von `create-pod.sh`: `--yes`, `--online`, `--ssh` (öffnet zusätzlich 22/tcp; für dieses Image nicht
geprüft), `--force` (ein zweiter Pool-Pod), `--terminate-on-fail`. Es lehnt einen doppelten Namen und einen
zweiten aktiven Pool-Pod ab, nimmt ein Host-Lock, damit nie zwei Anlegevorgänge gleichzeitig laufen,
**wiederholt nie eine Anfrage, die angekommen sein könnte**, und prüft den Pod danach. Fällt die Prüfung
durch, wird der Pod gestoppt und in `failed-<Name>-<ID>` umbenannt (mit `--terminate-on-fail` gelöscht).

Exit-Codes: 0 fertig oder geprüft, 1 Fehler, 2 falsche Argumente, 3 Name vergeben oder Pool-Pod aktiv,
4 anderer Start läuft, 5 keine Kapazität (nichts abgerechnet), 6 angelegt, aber nicht prüfbar (läuft weiter).

```bash
make verify        # GPU-ID und -Anzahl, Volume, Port, Env (MODEL, CTX, TP, SEQS, MMAP, ...), Key als Secret
make check         # ohne Key 401, mit Key 200, Modellname, Kontextlänge, Modellwurzel
make wait-ready    # wartet, bis vLLM antwortet; hängt die Zeit an .startup-times.log an
```

`verify` und `check` vergleichen gegen deine `.env`; nimm also dieselbe `.env`, mit der du angelegt hast.

## Alltag: starten, stoppen, löschen

- **Kosten beenden:** `make stop` (alle aktiven Pool-Pods). Ein gestoppter Pod gibt die GPU frei und behält
  seine Definition; das Volume bleibt. `make pod-stop` tut dasselbe für `RUNPOD_POD_ID`.
- **Wieder starten:** `make start` startet einen gestoppten Pool-Pod neu oder legt einen neuen an. Ein
  neu gestarteter Pod läuft auf seiner **alten Maschine** mit seinen **alten Einstellungen**; war die GPU
  dieser Maschine inzwischen vergeben, wird der Start abgelehnt (Exit 5, nichts abgerechnet), und
  `make start-when-free ARGS='1200 30'` wiederholt ihn. Einstellungen ändern sich bei einem Neustart nie.
  Zum Ändern löschen und neu anlegen.
- **Pod löschen:** `make pod-terminate ARGS='--yes <POD_ID>'`. Das Volume bleibt unberührt. Der Pod-Name
  bleibt vergeben, bis der alte Pod weg ist, und blockiert ein neues `make create` (Exit 3).
- **Caches:** Der vLLM-Compile-Cache, die FlashInfer-Autotune-Ergebnisse und das Modell bleiben auf dem
  Volume, ein späterer Start überspringt also den Download und das meiste Kompilieren.

## Logs und Fehlersuche

`make logs ARGS='--tail 200'` streamt Container- und System-Logs; mit `--source container` fallen die
Zeilen vom Image-Pull weg. Strg-C beendet es (`docker ps --filter ancestor=runpod-qwen38-tools` findet einen
übrig gebliebenen Container). **Nach einem fehlgeschlagenen Start startet der Pod vLLM in einer Schleife neu
und rechnet weiter ab.** Lies die ersten Minuten des Logs und stoppe oder lösche einen fehlgeschlagenen Pod.

| Symptom | Ursache | Was tun |
|---|---|---|
| `NotImplementedError: NVFP4 PLE supports TP=1 only` | `GPU_COUNT` 2 oder mehr: der PLE-Loader von Patch 20 kann nur eine GPU (gesehen bei 2× RTX PRO 6000) | `GPU_COUNT=1` auf einer Karte mit genug Speicher |
| `Available KV cache memory: -10.45 GiB`, dann `No available memory for the cache blocks` | die Gewichte (102,87 GiB) plus Zusatzbedarf passen bei 0,90 nicht auf eine 141-GB-Karte | `PLE_MMAP=1` mit lokalem Modellpfad (spart etwa 27 GiB; gesehen auf der H200) |
| `MMAP=1 requires MODEL=/local/path/...` | `MODEL` ist eine Hugging-Face-ID | `MODEL` auf das Snapshot-Verzeichnis auf dem Volume setzen |
| `A Pod named '...' already exists` (Exit 3) | der alte Pod existiert noch, auch gestoppt | löschen (`make pod-terminate`) oder `POD_NAME` setzen |
| `no capacity` (Exit 5) | im Rechenzentrum des Volumes ist keine GPU frei | `make wait-gpu`, dann wiederholen; nichts wurde abgerechnet |
| `make check`: mit deinem Key HTTP 401 | das Secret `VLLM_API_KEY` des Pods fehlt oder weicht von `.env` ab | Secret mit gleichem Wert anlegen, Pod neu anlegen |
| HTTP 403, Inhalt `error code: 1010`, vom eigenen Python- oder anderen Client | der RunPod-Proxy (Cloudflare) blockt den Standard-User-Agent von Python; `curl` wird nicht geblockt | einen anderen `User-Agent`-Header setzen, zum Beispiel `curl/8.5.0` |
| HTTP 400 `Unexpected reasoning effort high. Supported types are xhigh (default), medium, and low` | die Chat-Vorlage des Modells lehnt `reasoning_effort`-Werte außer xhigh, medium und low ab; viele Clients senden `high` (am 2026-10-04 beim Image `:2` gesehen) | Image `:3` nutzen (dessen Entrypoint liefert eine angepasste Vorlage, die high und max auf xhigh und minimal auf low abbildet), oder xhigh, medium oder low senden |
| `unknown datacenter 'PRO'` bei `make gpu` | ein GPU-Name mit Leerzeichen wurde zerlegt | in Anführungszeichen: `ARGS='"RTX PRO 6000"'` |
| `Datacenter X does not support Network Volumes` | nicht jedes Rechenzentrum hat Volumes | ein anderes wählen (`make volume` prüft vorher) |
| `Unknown vLLM environment variable VLLM_PLE_NVFP4*` | die Variablen gehören dem Patch, nicht vLLM | harmlos |
| `Triton kernel JIT compilation during inference` nach den ersten Anfragen | Kernel werden beim ersten Gebrauch einmalig kompiliert | harmlos, einmaliger Latenz-Ausschlag |
| Hopper: `FlashInfer GDN prefill is JIT-compiled` | der Kernel für die lineare Aufmerksamkeit wird beim Warm-up kompiliert | lief auf der H200; scheitert er, `VLLM_EXTRA_ARGS="--gdn-prefill-backend triton"` |
| `GPU does not have native support for FP4` (H200) | Hopper hat keine FP4-Tensor-Cores; vLLM nutzt das Marlin-Weight-only-Backend | erwartet; bei rechenintensiven Lasten eventuell langsamer |

## Speicher, Kontext und Parallelität

Alle Zahlen stammen vom validierten H200-Lauf (141-GB-Karte, `GPU_MEMORY_UTILIZATION=0.90`, `PLE_MMAP=1`).

| Größe | Wert |
|---|---|
| Modell im GPU-Speicher | 76,04 GiB (102,87 GiB ohne mmap) |
| KV-Cache | 46,75 GiB = **1.575.594 Tokens** (etwa 33.700 Tokens je GiB) |
| Parallelität bei 131.072 Tokens | 12,02× |
| Parallelität bei 262.144 Tokens, `MAX_MODEL_LEN=262144`, `MAX_NUM_SEQS=6` | **6,45×**: vLLM meldet dann 1.690.023 Tokens für 46,76 GiB |

- Der KV-Cache ist ein fester Vorrat an Tokens, den alle Anfragen teilen. `MAX_NUM_SEQS × MAX_MODEL_LEN` soll
  höchstens so groß sein wie die Tokenzahl, die vLLM ausgibt; vLLM meldet die sich ergebende
  `Maximum concurrency`.
- **6 Sitzungen mit der vollen nativen Länge** (`MAX_MODEL_LEN=262144`, `MAX_NUM_SEQS=6`): **Start validiert**:
  Der KV-Cache fasst 1.690.023 Tokens, 6,45× Parallelität bei 262.144, etwa 7 % Reserve. Die Tokenzahl je GiB
  ist nicht konstant (33.700 bei 131.072, 36.150 bei 262.144); lies die Zahl ab, die vLLM ausgibt, statt
  umzurechnen. Darauf getestet: 6 gleichzeitige kurze Anfragen (je 200 Tokens) waren in 7,2 s alle fertig
  (zusammen 167 Tokens/s, etwa 28 je Strom, über den RunPod-Proxy), und ein verstecktes Codewort in der Mitte
  eines synthetischen Textes wurde bei 56.188 und bei 170.671 Prompt-Tokens gefunden (5,4 s und 13,5 s, etwa
  12.000 Prompt-Tokens/s). Lange Läufe: Ein Prompt mit 254.572 Tokens (97 % der Grenze) lieferte beide
  versteckten Schlüssel (bei 20 % und 80 %) in 21 s; **sechs gleichzeitige Prompts mit je 248.177 Tokens**
  (1.489.060 Tokens, 88 % des KV-Caches, jeder mit eigenem Text und eigener Schlüsselposition von 10 % bis
  90 %) lieferten alle den richtigen Schlüssel, in je 61 bis 108 s und insgesamt 108 s (etwa 13.800
  Prompt-Tokens/s). Im gefilterten Pod-Log erschien kein Fehler. **Nicht getestet:** alles über den nativen
  262.144 (YaRN), Schlussfolgern über echte Dokumente, Antwortqualität am Ende des Kontextes, gleichzeitiges
  langes Generieren. Einen versteckten Schlüssel in synthetischem, sich wiederholendem Text zu finden, ist eine
  leichte Aufgabe; es zeigt, dass Cache, Scheduler und der Pfad für langen Kontext funktionieren, nicht wie gut
  das Modell über lange Eingaben schlussfolgert.
- **Die Grenze des Modells ist 262.144** (`max_position_embeddings`; Rope-Typ `default`, keine Skalierung).
  Mehr braucht eine Rope-Skalierung. Die offizielle Modellkarte (`Qwen/Qwen3.8-Flash-Next`) sagt „262,144
  natively and extensible up to 1,000,000 tokens“ mit **statischem YaRN** und nennt die vLLM-Einstellung:
  `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1`, `--max-model-len 1000000` und `--hf-overrides` mit
  `text_config.rope_parameters` = `rope_type yarn`, `factor 4.0` (2.0 für 524.288),
  `original_max_position_embeddings 262144`, `rope_theta 10000000`, `partial_rotary_factor 0.25`,
  `mrope_interleaved true`, `mrope_section [11,11,10]`. Die Karte warnt, dass statisches YaRN kurze Texte
  verschlechtern kann; setze es also nur bei Bedarf. Alle Varianten teilen die 262.144-Konfiguration; es gibt
  keine eigenen 1M-Gewichte (das „1M by default“ von Qwen3.8-Flash ist Qwens gehostetes Produkt).
  **Hier ungetestet:** diese Einstellung mit diesem NVFP4-Build und den Patches, die Qualität bei 1M und die
  Zeit für das Einlesen.
- **Was bei 33.700 Tokens je GiB auf die H200 passt:** 1 × 1M-Sitzung braucht 29,7 der 46,75 GiB (passt),
  3 × 500k brauchen 44,5 GiB (passt knapp), 6 × 1M bräuchten etwa 187 GiB (passt nicht).
- Der KV-Cache bleibt BF16: Das Rezept meldet, dass die Aufmerksamkeitsschichten einen FP8-KV-Cache ablehnen.
- Die Geschwindigkeit bei sehr langen Prompts wurde nicht gemessen. Auf Hopper läuft der FP4-Pfad nur für
  die Gewichte (Marlin), das ist bei rechenintensiver Arbeit langsamer.

## GPUs und was validiert wurde

| Aufbau | Ergebnis |
|---|---|
| 1× H200 SXM, CA-MTL-3, `PLE_MMAP=1` | **validiert am 2026-10-04**: startet, besteht `make check`, beantwortet Chat- und Anthropic-API-Anfragen (siehe unten) |
| 1× H200 SXM ohne mmap | **scheitert**: der KV-Cache wäre −10,45 GiB |
| 2× RTX PRO 6000 (Blackwell, je 96 GB), TP=2 | **scheitert**: `PLE supports TP=1 only` |
| 1× RTX PRO 6000 mit mmap | ungetestet; etwa 80 GB Gewichte auf 96 GB sind knapp |
| 1× B200 | das eigentliche Ziel; **nie gelaufen**, keine war frei |

Was der H200-Lauf zeigte: Das Marlin-Weight-only-NVFP4-MoE-Backend läuft auf Hopper; der Start von der
ersten vLLM-Logzeile bis „bereit“ dauerte etwa 5,5 Minuten bei bereits vorhandenem Modell auf dem Volume;
`make check` bestand alle fünf Prüfungen; zwei kurze Chat-Anfragen ergaben stimmige deutsche Antworten mit
vom Inhalt getrenntem Denken (die zweite lief mit etwa 68 Tokens/s, gerechnet bis zum Ende über den
RunPod-Proxy; die erste enthielt das einmalige Triton-JIT). Das ist ein Pod und zwei kurze Anfragen, kein
Benchmark.

Listenpreise aus dem RunPod-Console am 2026-10-04 (nicht per API gelesen): B200 6,79 $/h, H200 SXM 4,59 $/h,
RTX PRO 6000 2,09 $/h, B300 7,89 $/h. Der Bestand war bei der B200 „keiner“, bei der H200 SXM in den meisten
Rechenzentren „niedrig“.

## Claude Code

`scripts/claude-qwen.sh` läuft auf **deinem Rechner** und braucht `claude` im PATH:

```bash
set -a; source .env; set +a
scripts/claude-qwen.sh            # Argumente gehen an claude
```

Es löst den einen aktiven Pool-Pod auf (sonst `RUNPOD_POD_ID`, sonst `QWEN_URL`), nennt welchen und warum,
wartet auf `/v1/models` und setzt dann `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` (dein `VLLM_API_KEY`),
`CLAUDE_CODE_MAX_CONTEXT_TOKENS` (aus `MAX_MODEL_LEN`) und die Aliase für Haiku, Sonnet und Opus (alle
`qwen3.8-flash-next`, damit Hintergrundaufrufe nicht mit 404 scheitern), und startet
`claude --model qwen3.8-flash-next`. Es liest nur; es startet nie einen Pod. Exit-Codes: 1 kein Pod oder nie
bereit, 2 `VLLM_API_KEY` fehlt, 127 kein `claude`.

Gegen den H200-Pod geprüft: `POST /v1/messages` (Denk-Block plus Text), `POST /v1/messages/count_tokens` und
ein `tool_use`-Durchlauf funktionieren; die Pod-Auflösung und die Variablen des Skripts wurden mit einem
Platzhalter für `claude` getestet. **Der Betreiber hat danach eine echte Claude-Code-Sitzung gefahren** (am
2026-10-04, die Bitte, das Repo zusammenzufassen): Sie antwortete mit Werkzeugnutzung („listed 2 directories“),
und die Zusammenfassung stimmte zum Repo. In der Antwort rutschte dem Modell ein chinesisches Wort in einen
deutschen Satz (eine Stichprobe, kein Maß). Im selben Zeitraum protokollierte der Server Anfragen, die mit
`Unexpected reasoning effort high` abgelehnt wurden (siehe Fehlersuche); die Sitzung antwortete trotzdem, und ob
Claude Code ohne den Wert neu angefragt hat oder ob es Hintergrundaufrufe waren, ist nicht bekannt. Image `:3`
entfernt die Ablehnungen (geprüft, siehe „Eigenes Image bauen“). **Nicht getestet:** längere Sitzungen.

## Der Pod-Pool

Der Pool sind alle Pods, deren Name mit `POOL_PREFIX` beginnt (Standard `qwen3.8-flash-next`) und die nicht
gelöscht sind; er wird live gelesen, es werden keine IDs gespeichert. `make start` und `make stop` arbeiten auf
dem Pool. Neue Pods bekommen eindeutige Namen (`qwen3.8-flash-next`, `qwen3.8-flash-next-2`, ...), höchstens
`POOL_MAX`.

- Zwei Pool-Pods laufen nie gleichzeitig (sie würden `/workspace/vllm-cache` teilen und doppelt kosten):
  `create`, `start` und `pod-start` lehnen das ab (Exit 3 oder 9), außer mit `--force`.
- `make start` versucht zuerst, die gestoppten Pool-Pods nacheinander neu zu starten (ein fehlgeschlagener
  Versuch kostet nichts) und legt nur dann einen neuen an, wenn keiner startet. `ARGS=--no-create` verbietet
  das Anlegen, `ARGS=--dry-run` zeigt den Plan, `ARGS=--wait` führt zusätzlich `wait-ready` aus. Ein
  Host-Lock erlaubt auf deinem Rechner nur einen Start oder Anlegevorgang gleichzeitig; ein zweiter endet
  mit 4. `make abort` stoppt einen hängenden.
- Alle Pods eines Pools teilen ein Volume und liegen deshalb in dessen Rechenzentrum.
- Der Start wird von diesem Repo nicht zeitgesteuert. Das GLM-Repo, von dem es abstammt, hat ein
  GitHub-Actions-Beispiel für einen täglichen Start und Stopp; es wurde nicht übernommen.

## Eigenes Image bauen

`image/` enthält den Build-Kontext; `image/README.md` die Pins. Kurz:

```bash
IMAGE=docker.io/DU/vllm-qwen38-b200:3 image/build.sh
docker push docker.io/DU/vllm-qwen38-b200:3        # danach REMOTE_IMAGE per Digest festlegen
```

Die Basis ist das linux/amd64-Manifest von `vllm/vllm-openai:qwen38-flash-next`, per Digest festgelegt. Der
Rezept-Commit ist ebenfalls festgelegt. Der Build wendet die Patches 20, 30, 35, 40 und 41 an und scheitert,
wenn deren Marker fehlen. Patch 10 (ein sm121-Marlin-Workaround) wird absichtlich übersprungen. Das
veröffentlichte Image ist `pt9912/vllm-qwen38-b200:3` (Digest in `.env.example`); `:2` ist das der validierten Läufe,
`:3` ergänzt die Chat-Vorlagen-Korrektur und wurde am 2026-10-04 auf einem Pod geprüft (gleicher KV-Cache und Start wie bei
`:2`; `reasoning_effort` `high`, `max` und `minimal` antworten jetzt mit HTTP 200, ein ungültiger Wert wie `bogus` wird
weiter mit 400 abgelehnt).

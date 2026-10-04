# runpod-qwen38-flash-next

Deutsch | [English](README.md) · [Anleitung](docs/guide.de.md) · [Startzeiten](docs/startup-times.de.md)

Bash-Werkzeuge, um **Qwen3.8-Flash-Next (NVFP4)** mit vLLM auf **einer NVIDIA H200 SXM** (validiert) oder
einer anderen einzelnen GPU in RunPod Secure Cloud zu betreiben: einen Pod über die RunPod-REST-API **v2**
(`https://api.runpod.io/v2`) anlegen, prüfen, starten, stoppen und testen. Alles läuft über `make` in einem
kleinen Docker-Image.

Die Lifecycle-Skripte stammen von [pt9912/runpod-glm](https://github.com/pt9912/runpod-glm) ab; das
Serving-Image (`image/`) und das Modell-Rezept kommen von
[starkweatherdigital/qwen3.8-flash-next-nvfp4-recipe](https://github.com/starkweatherdigital/qwen3.8-flash-next-nvfp4-recipe).
Die [Anleitung](docs/guide.de.md) enthält alles, was über diese Seite hinausgeht.

## Status

**Einmal validiert, am 2026-10-04:** 1× **H200 SXM** (Secure Cloud, CA-MTL-3) mit `PLE_MMAP=1`, Image `:2`.
Von vLLM-Start bis `Application startup complete` dauerte es etwa 5,5 Minuten (das Modell lag schon auf dem
Volume). `make check` bestand alle fünf Prüfungen, und zwei kurze Chat-Anfragen ergaben stimmige deutsche
Antworten mit herausgelöstem Denken. Die Anthropic-artigen Endpunkte `/v1/messages` und `count_tokens` sowie
ein `tool_use`-Durchlauf funktionieren ebenfalls. Das ist ein Pod und zwei kurze Anfragen, kein Benchmark.

Was dieser Lauf und die fehlgeschlagenen Versuche gezeigt haben:

- **PLE-mmap ist bei einer 141-GB-Karte nötig.** Ohne belegen die Gewichte 102,87 GiB, und vLLM meldet
  `Available KV cache memory: -10.45 GiB` und startet nicht. Mit `PLE_MMAP=1` braucht das Modell 76,04 GiB und
  lässt **46,75 GiB** KV-Cache übrig (1.575.594 Tokens: 12-fache Parallelität bei 131.072 Tokens, 6-fache bei
  262.144).
- **Hopper hat kein natives FP4:** vLLM nutzt das Marlin-Weight-only-NVFP4-Backend. Es funktioniert, bei
  rechenintensiven Lasten kann es aber langsamer sein.
- **Tensor-Parallelität geht mit diesem Rezept nicht:** `GPU_COUNT=2` bricht mit
  `NotImplementedError: NVFP4 PLE supports TP=1 only` ab. 2× RTX PRO 6000 scheiterte dort. Nimm eine Karte.
- **Ein abgestürzter Pod startet vLLM in einer Schleife neu und rechnet weiter ab.** Die ersten Minuten von
  `make logs` ansehen.
- **Die Kontextgrenze des Modells ist 262.144 Tokens.** Mehr bräuchte Rope-Skalierung (ungetestet).

Nicht erledigt: ein B200-Lauf (keine war frei), eine echte interaktive Claude-Code-Sitzung, Tests mit langem
Kontext und jeder echte Benchmark. Das arm64-Image von Upstream (`jstarkg/vllm-gb10-flashnext`) läuft nicht auf
x86-GPUs; `create-pod.sh` weist es ab. Der KV-Cache bleibt absichtlich BF16 (das Rezept meldet, dass die
Aufmerksamkeitsschichten FP8 ablehnen).

## Schnellstart

```bash
cp .env.example .env && $EDITOR .env      # RUNPOD_API_KEY, VLLM_API_KEY; REMOTE_IMAGE ist schon gesetzt
make precheck ARGS=--online               # Werkzeuge, .env, API-Key
make gpu ARGS='"NVIDIA H200"'             # Bestand je Rechenzentrum (Namen mit Leerzeichen in Anführungszeichen)
```

1. **Secrets:** im RunPod-Console `VLLM_API_KEY` (gleicher Wert wie in `.env`) und `HF_TOKEN` anlegen.
2. **Network Volume** (150 GB) in einem Rechenzentrum mit Bestand, das Volumes anbietet:
   ```bash
   make volume ARGS='--dc CA-MTL-3'         # Trockenlauf: Request und Monatskosten (etwa 10,50 $)
   make volume ARGS='--dc CA-MTL-3 --yes'   # legt es an und gibt NETWORK_VOLUME_ID für .env aus
   ```
3. **Erster Start** auf dem leeren Volume lädt das 109-GB-Modell (`GPU_ID="NVIDIA H200"`, `GPU_COUNT=1`):
   ```bash
   make create                          # Trockenlauf: zeigt den Request, legt nichts an
   make create ARGS='--yes --online'    # legt den Pod an; die GPU wird ab jetzt abgerechnet
   make logs                            # Download und vLLM-Start verfolgen
   ```
4. **Spätere Starts** nutzen das Modell vom Volume mit `PLE_MMAP=1` (auf der H200 nötig). In `.env`:
   ```
   GPU_ID="NVIDIA H200"
   GPU_COUNT=1
   PLE_MMAP=1
   MODEL=/workspace/huggingface/hub/models--starkweatherdigital--qwen3.8-flash-next-nvfp4/snapshots/1b304e5f99de0faaf43c3a959f2b4000294bf65c
   ```
   dann `make create ARGS=--yes`. Das Snapshot-Verzeichnis ist die Hugging-Face-Revision des Modells.
5. `make wait-ready`, `make check`, und zum Schluss `make stop` (das Volume behält Modell und Caches).

Sechs Sitzungen mit dem vollen nativen Kontext: `MAX_MODEL_LEN=262144` und `MAX_NUM_SEQS=6` ergänzen (passt
fast ohne Reserve; noch nicht gelaufen). `make help` listet alle Ziele.

## Claude Code

`scripts/claude-qwen.sh` startet Claude Code gegen den Pod, auf **deinem Rechner** (nicht über `make`):

```bash
set -a; source .env; set +a
scripts/claude-qwen.sh            # Argumente gehen an claude
```

Es löst den aktiven Pod auf, wartet auf den Endpunkt und setzt die Anthropic-Variablen. Es startet nie einen
Pod. Mit einem Platzhalter für `claude` geprüft; eine echte interaktive Sitzung ist ungetestet. Details in der
[Anleitung](docs/guide.de.md#claude-code).

## Dokumentation

| | |
|---|---|
| [docs/guide.de.md](docs/guide.de.md) | die ganze Anleitung: Architektur, jedes Skript, Einstellungen, Volume, Fehlersuche, Speicherrechnung |
| [docs/startup-times.de.md](docs/startup-times.de.md) | gemessene Startphasen |
| [image/README.md](image/README.md) | das Pod-Image, seine Pins und Patches (englisch) |

## Was sich vom GLM-Repo unterscheidet

Das Qwen-Modell und das Profil oben statt GLM auf einer B300, Serving über Umgebungsvariablen am
Image-Entrypoint, ein verpflichtendes `REMOTE_IMAGE`, das nicht das arm64-Image sein darf, `make volume`, die
Einstellungen `GPU_ID`/`GPU_COUNT`/`MAX_NUM_SEQS` und Prüfungen in `verify-pod.sh` / `check-endpoint.sh` für
die Qwen-Einstellungen. Pool-, Lock-, Retry- und Aufräumlogik sind unverändert. Das Tools-Image ist dasselbe
minimale Alpine-Image; vLLM läuft darin nie.

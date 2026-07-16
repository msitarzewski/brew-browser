# Capability Baselines (as of July 2026)

The `requires` / `capabilityNotes` numbers behind the first-party recipes, and the reasoning so future maintainers can retune them. Gating uses **unified memory** as the dominant signal on Apple Silicon (VRAM == RAM); Intel Macs are supported but flagged where GPU/Neural-Engine acceleration matters. All package tokens/versions verified against local `brew` on 2026-07-12.

> These are **starting** thresholds — `requires` lives in `bundles.json` and is retunable via live-refresh (M5) without an app release.

---

## Local LLMs — `ollama` (formula) + `open-webui` (cask)
Both in official taps (`homebrew/core`, `homebrew/cask`); no tap-trust. Ollama = the CLI/server (`brew services start ollama`, API on **:11434**); Open WebUI = the browser front-end (default **:8080**), talks to the local Ollama server.

**Requirements reasoning (July 2026):** Ollama's own floor is **8 GB RAM, ~10 GB disk, no GPU required**. RAM need scales with model size, and 4-bit (Q4_K_M) is the consumer default (~0.6 GB per billion params):

| Unified memory | Practical capability | Verdict |
|---|---|---|
| < 8 GB | not viable | ❌ Not recommended |
| 8 GB | ~7–8B (Q4) only; larger swaps | ⚠️ Marginal |
| 16 GB | 13–14B comfortably (the sweet spot) | ✅ Ready |
| 24 GB | 26–32B class (Qwen/Gemma) | ✅ Ready |
| 48–64 GB+ | 70B (Q4 ≈ 40 GB) + MoE | ✅ Ready |

Apple-Silicon note: unified memory counts fully as VRAM, so an M-series Mac punches far above a same-price discrete GPU (a 64 GB Mac runs 70B locally). Intel Macs run Ollama but without Metal/ANE acceleration → slow; flag `gpu: preferred`, `arch: any`.

**Recipe `requires`:** `minRamGB: 8, recommendedRamGB: 16, minDiskGB: 12, arch: any, gpu: preferred`.

**Further reading (verified):**
- [Ollama](https://ollama.com) · [docs.ollama.com/quickstart](https://docs.ollama.com/quickstart) · [github.com/ollama/ollama](https://github.com/ollama/ollama)
- [Open WebUI](https://openwebui.com) · [docs.openwebui.com](https://docs.openwebui.com)
- Capability guide: [How Much RAM for Local LLMs? (2026)](https://tensorrigs.com/blog/ram-for-local-llm/) · [Ollama model RAM/VRAM table (2026)](https://localaimaster.com/blog/ollama-model-ram-vram-table)

---

## Image Gen — `comfy` (cask)
ComfyUI's cask token is **`comfy`** (`comfyui` is an alias → `comfy`); `homebrew/cask`, no tap-trust. Node-graph image-generation front-end.

**Requirements reasoning (July 2026):** ComfyUI itself claims broad flexibility — "can run large models on GPUs with as low as 1 GB VRAM with smart offloading" — and shipped **Dynamic VRAM on by default in early 2026**, so an 8 GB machine *can* run Flux 2 Dev. But *comfortable* image gen has real floors: **SDXL wants ≥ 8 GB VRAM (any M-series Mac with 16 GB unified is fine); Flux.1 dev fp8 ≈ 12 GB, and ≈ 24 GB at fp16.** Apple Silicon uses MPS (an MLX path exists, ~70% faster) but is roughly **2–4× slower per image than a comparable NVIDIA GPU**. Models are large on disk (SDXL checkpoints ~7 GB; Flux ~24 GB) and are **not** installed by brew — the cask installs the app; you download models yourself.

| Unified memory | Practical capability | Verdict |
|---|---|---|
| < 16 GB | SDXL only with offloading, slow | ⚠️ Marginal |
| 16 GB | SDXL comfortably; Flux fp8 with offloading | ✅ Ready |
| 24 GB | Flux fp8 comfortably | ✅ Ready |
| 48–64 GB+ | Flux fp16 | ✅ Ready |

Intel Macs: impractical (no MPS acceleration) → `gpu: required` effectively excludes them via the reason string. On Linux, GPU detection is best-effort (nvidia-smi); degrade to a disk-only check + GPU note.

**Recipe `requires`:** `minRamGB: 16, recommendedRamGB: 24, minDiskGB: 30, arch: apple-silicon, gpu: required`. Strong `caveats`: installs ComfyUI; you still download models (many GB) and generation is slower than NVIDIA.

**Further reading (verified):**
- [ComfyUI (github.com/comfyanonymous/ComfyUI)](https://github.com/comfyanonymous/ComfyUI) · [comfy.org](https://www.comfy.org)
- Capability guides: [Image Generation VRAM Requirements 2026](https://willitrunai.com/blog/image-generation-vram-guide-2026) · [ComfyUI VRAM Requirements (GIGAGPU)](https://gigagpu.com/comfyui-vram-requirements/)

---

## Graphics / Design — `inkscape`, `gimp`, `krita` (casks)
All `homebrew/cask`. Vector (Inkscape 1.4.4), raster (GIMP 3.2.4), digital painting (Krita 5.3.2.1). **No hardware gate** — run on any supported Mac; `requires` omitted → always Ready. Disk note only (~2–3 GB combined).

**Further reading (verified):** [inkscape.org](https://inkscape.org) · [gimp.org](https://www.gimp.org) · [krita.org](https://krita.org)

---

## Media Toolkit — `ffmpeg`, `yt-dlp`, `mpv` (formulae)
All `homebrew/core` (ffmpeg 8.1.2, yt-dlp 2026.7.4, mpv 0.41.0). CLI transcoding/download/playback. **No hardware gate.** (A GUI `handbrake` cask can be added; the `handbrake` *formula* is the CLI `HandBrakeCLI`.)

**Further reading (verified):** [ffmpeg.org](https://ffmpeg.org) · [github.com/yt-dlp/yt-dlp](https://github.com/yt-dlp/yt-dlp) · [mpv.io](https://mpv.io)

---

## Web Dev — `node` (formula) + …
`homebrew/core` (node 26.5.0). Light footprint; no meaningful hardware gate. Final package set TBD at build (candidates: `node`, `pnpm`, `caddy`). Setup guidance points at the runtimes.

**Further reading (verified):** [nodejs.org](https://nodejs.org)

---

## Databases — `postgresql@16`, `redis` (formulae)
`homebrew/core` (postgresql@16 = 16.14, redis 8.8.0). Light RAM; the value is **service** setup (`brew services start postgresql@16` / `redis`). Disk grows with data. No install-time hardware gate; `requires` omitted or a small `minDiskGB`.

**Further reading (verified):** [postgresql.org](https://www.postgresql.org) · [redis.io](https://redis.io) · [Homebrew services](https://docs.brew.sh/Manpage#services-subcommand)

---

## Link-verification note
Primary sources (project homepages from brew cask metadata, official repos, `docs.ollama.com`) were reachable on 2026-07-12. `docs.openwebui.com` bot-blocks automated HEAD requests (real site; whitelist in the CI link-checker). The capability *guide* links are secondary/SEO and used only as "further reading" — the threshold numbers are grounded in the primary docs + the reasoning above.
